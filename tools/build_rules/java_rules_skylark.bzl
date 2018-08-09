# Copyright 2014 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

java_filetype = FileType([".java"])
jar_filetype = FileType([".jar"])
srcjar_filetype = FileType([".jar", ".srcjar"])

# This is a quick and dirty rule to make Bazel compile itself. It's not
# production ready.

def java_library_impl(ctx):
    javac_options = ctx.fragments.java.default_javac_flags
    class_jar = ctx.outputs.class_jar
    compile_time_jars = depset(order = "topological")
    runtime_jars = depset(order = "topological")
    for dep in ctx.attr.deps:
        compile_time_jars += dep.compile_time_jars
        runtime_jars += dep.runtime_jars

    jars = jar_filetype.filter(ctx.files.jars)
    neverlink_jars = jar_filetype.filter(ctx.files.neverlink_jars)
    compile_time_jars += jars + neverlink_jars
    runtime_jars += jars
    compile_time_jars_list = list(compile_time_jars)  # TODO: This is weird.

    build_output = class_jar.path + ".build_output"
    java_output = class_jar.path + ".build_java"
    javalist_output = class_jar.path + ".build_java_list"
    sources = ctx.files.srcs

    sources_param_file = ctx.new_file(ctx.bin_dir, class_jar, "-2.params")
    ctx.file_action(
        output = sources_param_file,
        content = cmd_helper.join_paths("\n", depset(sources)),
        executable = False,
    )

    # Cleaning build output directory
    cmd = "set -e;rm -rf " + build_output + " " + java_output + " " + javalist_output + "\n"
    cmd += "mkdir " + build_output + " " + java_output + "\n"
    files = " @" + sources_param_file.path
    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jar_path = "%s/bin/jar" % java_runtime.java_home

    if ctx.files.srcjars:
        files += " @" + javalist_output
        for file in ctx.files.srcjars:
            cmd += "%s tf %s | grep '\.java$' | sed 's|^|%s/|' >> %s\n" % (jar_path, file.path, java_output, javalist_output)
            cmd += "unzip %s -d %s >/dev/null\n" % (file.path, java_output)

    if ctx.files.srcs or ctx.files.srcjars:
        cmd += "%s/bin/javac" % java_runtime.java_home
        cmd += " " + " ".join(javac_options)
        if compile_time_jars:
            cmd += " -classpath '" + cmd_helper.join_paths(ctx.configuration.host_path_separator, compile_time_jars) + "'"
        cmd += " -d " + build_output + files + "\n"

    # We haven't got a good story for where these should end up, so
    # stick them in the root of the jar.
    for r in ctx.files.resources:
        cmd += "cp %s %s\n" % (r.path, build_output)
    cmd += (jar_path + " cf " + class_jar.path + " -C " + build_output + " .\n" +
            "touch " + build_output + "\n")
    ctx.action(
        inputs = (sources + compile_time_jars_list + [sources_param_file] +
                  ctx.files._jdk + ctx.files.resources + ctx.files.srcjars),
        outputs = [class_jar],
        mnemonic = "JavacBootstrap",
        command = cmd,
        use_default_shell_env = True,
    )

    runfiles = ctx.runfiles(collect_data = True)

    return struct(
        files = depset([class_jar]),
        compile_time_jars = compile_time_jars + [class_jar],
        runtime_jars = runtime_jars + [class_jar],
        runfiles = runfiles,
    )

def java_binary_impl(ctx):
    library_result = java_library_impl(ctx)

    deploy_jar = ctx.outputs.deploy_jar
    manifest = ctx.outputs.manifest
    build_output = deploy_jar.path + ".build_output"
    main_class = ctx.attr.main_class
    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jar_path = "%s/bin/jar" % java_runtime.java_home
    ctx.file_action(
        output = manifest,
        content = "Main-Class: " + main_class + "\n",
        executable = False,
    )

    # Cleaning build output directory
    cmd = "set -e;rm -rf " + build_output + ";mkdir " + build_output + "\n"
    for jar in library_result.runtime_jars:
        cmd += "unzip -qn " + jar.path + " -d " + build_output + "\n"
    cmd += (jar_path + " cmf " + manifest.path + " " +
            deploy_jar.path + " -C " + build_output + " .\n" +
            "touch " + build_output + "\n")

    ctx.action(
        inputs = list(library_result.runtime_jars) + [manifest] + ctx.files._jdk,
        outputs = [deploy_jar],
        mnemonic = "Deployjar",
        command = cmd,
        use_default_shell_env = True,
    )

    # Write the wrapper.
    executable = ctx.outputs.executable
    ctx.file_action(
        output = executable,
        content = "\n".join([
            "#!/bin/bash",
            "# autogenerated - do not edit.",
            "case \"$0\" in",
            "/*) self=\"$0\" ;;",
            "*)  self=\"$PWD/$0\";;",
            "esac",
            "",
            "if [[ -z \"$JAVA_RUNFILES\" ]]; then",
            "  if [[ -e \"${self}.runfiles\" ]]; then",
            "    export JAVA_RUNFILES=\"${self}.runfiles\"",
            "  fi",
            "  if [[ -n \"$JAVA_RUNFILES\" ]]; then",
            "    export TEST_SRCDIR=${TEST_SRCDIR:-$JAVA_RUNFILES}",
            "  fi",
            "fi",
            "",
            "jvm_bin=%s" % (ctx.attr._jdk[java_common.JavaRuntimeInfo].java_executable_exec_path),
            "if [[ ! -x ${jvm_bin} ]]; then",
            "  jvm_bin=$(which java)",
            "fi",

            # We extract the .so into a temp dir. If only we could mmap
            # directly from the zip file.
            "DEPLOY=$(dirname $self)/$(basename %s)" % deploy_jar.path,

            # This works both on Darwin and Linux, with the darwin path
            # looking like tmp.XXXXXXXX.{random}
            "SO_DIR=$(mktemp -d -t tmp.XXXXXXXXX)",
            "function cleanup() {",
            "  rm -rf ${SO_DIR}",
            "}",
            "trap cleanup EXIT",
            "unzip -q -d ${SO_DIR} ${DEPLOY} \"*.so\" \"*.dll\" \"*.dylib\" >& /dev/null",
            ("${jvm_bin} -Djava.library.path=${SO_DIR} %s -jar $DEPLOY \"$@\"" %
             " ".join(ctx.attr.jvm_flags)),
            "",
        ]),
        executable = True,
    )

    runfiles = ctx.runfiles(files = [deploy_jar, executable] + ctx.files._jdk, collect_data = True)
    files_to_build = depset([deploy_jar, manifest, executable])
    files_to_build += library_result.files

    return struct(files = files_to_build, runfiles = runfiles)

def java_import_impl(ctx):
    # TODO(bazel-team): Why do we need to filter here? The attribute
    # already says only jars are allowed.
    jars = depset(jar_filetype.filter(ctx.files.jars))
    neverlink_jars = depset(jar_filetype.filter(ctx.files.neverlink_jars))
    runfiles = ctx.runfiles(collect_data = True)
    return struct(
        files = jars,
        compile_time_jars = jars + neverlink_jars,
        runtime_jars = jars,
        runfiles = runfiles,
    )

java_library_attrs = {
    "_jdk": attr.label(
        default = Label("//tools/jdk:current_java_runtime"),
        providers = [java_common.JavaRuntimeInfo],
    ),
    "data": attr.label_list(allow_files = True),
    "resources": attr.label_list(allow_files = True),
    "srcs": attr.label_list(allow_files = java_filetype),
    "jars": attr.label_list(allow_files = jar_filetype),
    "neverlink_jars": attr.label_list(allow_files = jar_filetype),
    "srcjars": attr.label_list(allow_files = srcjar_filetype),
    "deps": attr.label_list(
        allow_files = False,
        providers = ["compile_time_jars", "runtime_jars"],
    ),
}

java_library = rule(
    java_library_impl,
    attrs = java_library_attrs,
    outputs = {
        "class_jar": "lib%{name}.jar",
    },
    fragments = ["java", "cpp"],
)

# A copy to avoid conflict with native rule.
bootstrap_java_library = rule(
    java_library_impl,
    attrs = java_library_attrs,
    outputs = {
        "class_jar": "lib%{name}.jar",
    },
    fragments = ["java"],
)

java_binary_attrs_common = dict(java_library_attrs)
java_binary_attrs_common.update({
    "jvm_flags": attr.string_list(),
    "jvm": attr.label(default = Label("//tools/jdk:jdk"), allow_files = True),
})

java_binary_attrs = dict(java_binary_attrs_common)
java_binary_attrs["main_class"] = attr.string(mandatory = True)

java_binary_outputs = {
    "class_jar": "lib%{name}.jar",
    "deploy_jar": "%{name}_deploy.jar",
    "manifest": "%{name}_MANIFEST.MF",
}

java_binary = rule(
    java_binary_impl,
    executable = True,
    attrs = java_binary_attrs,
    outputs = java_binary_outputs,
    fragments = ["java", "cpp"],
)

# A copy to avoid conflict with native rule
bootstrap_java_binary = rule(
    java_binary_impl,
    executable = True,
    attrs = java_binary_attrs,
    outputs = java_binary_outputs,
    fragments = ["java"],
)

java_test = rule(
    java_binary_impl,
    executable = True,
    attrs = dict(java_binary_attrs_common.items() + [
        ("main_class", attr.string(default = "org.junit.runner.JUnitCore")),
        # TODO(bazel-team): it would be better if we could offer a
        # test_class attribute, but the "args" attribute is hard
        # coded in the bazel infrastructure.
    ]),
    outputs = java_binary_outputs,
    test = True,
    fragments = ["java", "cpp"],
)

java_import = rule(
    java_import_impl,
    attrs = {
        "jars": attr.label_list(allow_files = jar_filetype),
        "srcjar": attr.label(allow_files = srcjar_filetype),
        "neverlink_jars": attr.label_list(allow_files = jar_filetype, default = []),
    },
)
