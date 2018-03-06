# pylint: disable=g-bad-file-header
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

import os
import tempfile
import unittest

from src.tools.runfiles import runfiles


class RunfilesTest(unittest.TestCase):
  # """Unit tests for `runfiles.Runfiles`."""

  def testRlocationArgumentValidation(self):
    r = runfiles.Create({"RUNFILES_DIR": "whatever"})
    self.assertRaises(ValueError, lambda: r.Rlocation(None))
    self.assertRaises(ValueError, lambda: r.Rlocation(""))
    self.assertRaises(TypeError, lambda: r.Rlocation(1))
    self.assertRaisesRegexp(ValueError, "contains uplevel",
                            lambda: r.Rlocation("foo/.."))
    if RunfilesTest.IsWindows():
      self.assertRaisesRegexp(ValueError, "is absolute",
                              lambda: r.Rlocation("\\foo"))
      self.assertRaisesRegexp(ValueError, "is absolute",
                              lambda: r.Rlocation("c:/foo"))
      self.assertRaisesRegexp(ValueError, "is absolute",
                              lambda: r.Rlocation("c:\\foo"))
    else:
      self.assertRaisesRegexp(ValueError, "is absolute",
                              lambda: r.Rlocation("/foo"))

  def testCreatesManifestBasedRunfiles(self):
    with _MockFile(contents=["a/b c/d"]) as mf:
      r = runfiles.Create({
          "RUNFILES_MANIFEST_FILE": mf.Path(),
          "RUNFILES_DIR": "ignored when RUNFILES_MANIFEST_FILE has a value",
          "TEST_SRCDIR": "always ignored",
      })
      self.assertEqual(r.Rlocation("a/b"), "c/d")
      self.assertIsNone(r.Rlocation("foo"))

  def testManifestBasedRunfilesEnvVars(self):
    with _MockFile(name="MANIFEST") as mf:
      r = runfiles.Create({
          "RUNFILES_MANIFEST_FILE": mf.Path(),
          "TEST_SRCDIR": "always ignored",
      })
      self.assertDictEqual(
          r.EnvVars(), {
              "RUNFILES_MANIFEST_FILE": mf.Path(),
              "RUNFILES_DIR": mf.Path()[:-len("/MANIFEST")],
              "JAVA_RUNFILES": mf.Path()[:-len("/MANIFEST")],
          })

    with _MockFile(name="foo.runfiles_manifest") as mf:
      r = runfiles.Create({
          "RUNFILES_MANIFEST_FILE": mf.Path(),
          "TEST_SRCDIR": "always ignored",
      })
      self.assertDictEqual(
          r.EnvVars(), {
              "RUNFILES_MANIFEST_FILE":
                  mf.Path(),
              "RUNFILES_DIR": (
                  mf.Path()[:-len("foo.runfiles_manifest")] + "foo.runfiles"),
              "JAVA_RUNFILES": (
                  mf.Path()[:-len("foo.runfiles_manifest")] + "foo.runfiles"),
          })

    with _MockFile(name="x_manifest") as mf:
      r = runfiles.Create({
          "RUNFILES_MANIFEST_FILE": mf.Path(),
          "TEST_SRCDIR": "always ignored",
      })
      self.assertDictEqual(
          r.EnvVars(), {
              "RUNFILES_MANIFEST_FILE": mf.Path(),
              "RUNFILES_DIR": "",
              "JAVA_RUNFILES": "",
          })

  def testCreatesDirectoryBasedRunfiles(self):
    r = runfiles.Create({
        "RUNFILES_DIR": "runfiles/dir",
        "TEST_SRCDIR": "always ignored",
    })
    self.assertEqual(r.Rlocation("a/b"), "runfiles/dir/a/b")
    self.assertEqual(r.Rlocation("foo"), "runfiles/dir/foo")

  def testDirectoryBasedRunfilesEnvVars(self):
    r = runfiles.Create({
        "RUNFILES_DIR": "runfiles/dir",
        "TEST_SRCDIR": "always ignored",
    })
    self.assertDictEqual(r.EnvVars(), {
        "RUNFILES_DIR": "runfiles/dir",
        "JAVA_RUNFILES": "runfiles/dir",
    })

  def testFailsToCreateManifestBasedBecauseManifestDoesNotExist(self):

    def _Run():
      runfiles.Create({"RUNFILES_MANIFEST_FILE": "non-existing path"})

    self.assertRaisesRegexp(IOError, "non-existing path", _Run)

  def testFailsToCreateAnyRunfilesBecauseEnvvarsAreNotDefined(self):
    with _MockFile(contents=["a b"]) as mf:
      runfiles.Create({
          "RUNFILES_MANIFEST_FILE": mf.Path(),
          "RUNFILES_DIR": "whatever",
          "TEST_SRCDIR": "always ignored",
      })
    runfiles.Create({
        "RUNFILES_DIR": "whatever",
        "TEST_SRCDIR": "always ignored",
    })
    self.assertIsNone(runfiles.Create({"TEST_SRCDIR": "always ignored"}))
    self.assertIsNone(runfiles.Create({"FOO": "bar"}))

  def testManifestBasedRlocation(self):
    with _MockFile(contents=[
        "Foo/runfile1", "Foo/runfile2 C:/Actual Path\\runfile2",
        "Foo/Bar/runfile3 D:\\the path\\run file 3.txt"
    ]) as mf:
      r = runfiles.CreateManifestBased(mf.Path())
      self.assertEqual(r.Rlocation("Foo/runfile1"), "Foo/runfile1")
      self.assertEqual(r.Rlocation("Foo/runfile2"), "C:/Actual Path\\runfile2")
      self.assertEqual(
          r.Rlocation("Foo/Bar/runfile3"), "D:\\the path\\run file 3.txt")
      self.assertIsNone(r.Rlocation("unknown"))

  def testDirectoryBasedRlocation(self):
    # The _DirectoryBased strategy simply joins the runfiles directory and the
    # runfile's path on a "/". This strategy does not perform any normalization,
    # nor does it check that the path exists.
    r = runfiles.CreateDirectoryBased("foo/bar baz//qux/")
    self.assertEqual(r.Rlocation("arg"), "foo/bar baz//qux/arg")

  @staticmethod
  def IsWindows():
    return os.name == "nt"


class _MockFile(object):

  def __init__(self, name=None, contents=None):
    self._contents = contents or []
    self._name = name or "x"
    self._path = None

  def __enter__(self):
    tmpdir = os.environ.get("TEST_TMPDIR")
    self._path = os.path.join(tempfile.mkdtemp(dir=tmpdir), self._name)
    with open(self._path, "wt") as f:
      f.writelines(l + "\n" for l in self._contents)
    return self

  def __exit__(self, exc_type, exc_value, traceback):
    os.remove(self._path)
    os.rmdir(os.path.dirname(self._path))

  def Path(self):
    return self._path


if __name__ == "__main__":
  unittest.main()
