# Copyright 2018 The Bazel Authors. All rights reserved.
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
'''Helpers to create golden tests, to minimize code duplication.'''

def create_golden_test(name, golden_file, has_bootclasspath, missing_jar = None, replacing_jar = None):
  '''Create a golden test for the dependency checker.'''
  all_dep_jars = [
      "testdata_client",
      "testdata_lib_Library",
      "testdata_lib_LibraryAnnotations",
      "testdata_lib_LibraryException",
      "testdata_lib_LibraryInterface",
      ]
  testdata_pkg = "//third_party/bazel/src/java_tools/import_deps_checker/javatests/com/google/devtools/build/importdeps/testdata"
  import_deps_checker = "//third_party/bazel/src/java_tools/import_deps_checker/java/com/google/devtools/build/importdeps:ImportDepsChecker"
  client_jar = testdata_pkg + ":testdata_client"
  data = [
      golden_file,
      import_deps_checker,
      "//third_party/java/jdk:jdk8_rt_jar"
      ] + [testdata_pkg + ":" + x for x in all_dep_jars]
  if (replacing_jar):
    data.append(testdata_pkg + ":" + replacing_jar)

  args = [
      "$(location %s)" % golden_file,
      "$(location %s)" % import_deps_checker,
      ]
  args.append("--bootclasspath_entry")
  if has_bootclasspath:
    args.append("$(location //third_party/java/jdk:jdk8_rt_jar)")
  else:
    args.append("$(location %s)" % client_jar) # Fake bootclasspath.

  for dep in all_dep_jars:
    if dep == missing_jar:
      if replacing_jar:
        args.append("--classpath_entry")
        args.append("$(location %s:%s)" % (testdata_pkg, replacing_jar))
      continue
    args.append("--classpath_entry")
    args.append("$(location %s:%s)" % (testdata_pkg, dep))

  args = args + [
      "--input",
      "$(location %s:testdata_client)" % testdata_pkg,
      ]
  native.sh_test(
      name=name,
      srcs = ["golden_test.sh"],
      args = args,
      data = data,
      )
