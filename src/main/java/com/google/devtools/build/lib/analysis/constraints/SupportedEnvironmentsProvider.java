// Copyright 2015 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package com.google.devtools.build.lib.analysis.constraints;

import com.google.devtools.build.lib.analysis.LabelAndLocation;
import com.google.devtools.build.lib.analysis.TransitiveInfoProvider;
import com.google.devtools.build.lib.cmdline.Label;

/**
 * A provider that advertises which environments the associated target is compatible with
 * (from the point of view of the constraint enforcement system).
 */
public interface SupportedEnvironmentsProvider extends TransitiveInfoProvider {

  /**
   * Returns the static environments this target is compatible with. Static environments
   * are those that are independent of build configuration (e.g. declared in {@code restricted_to} /
   * {@code compatible_with}). See {@link ConstraintSemantics} for details.
   */
  EnvironmentCollection getStaticEnvironments();

  /**
   * Returns the refined environments this rule is compatible with. Refined environments are
   * static environments with unsupported environments from {@code select}able deps removed (on the
   * principle that others paths in the select would have provided those environments, so this rule
   * is "refined" to match whichever deps got chosen).
   *
   * <p>>Refined environments require knowledge of the build configuration. See
   * {@link ConstraintSemantics} for details.
   */
  EnvironmentCollection getRefinedEnvironments();

  /**
   * If the given environment was refined away from this target's set of supported environments,
   * returns the dependency that originally removed the environment.
   *
   * <p>For example, if the current rule is restricted_to [E] and depends on D1, D1 is restricted_to
   * [E] and depends on D2, and D2 is restricted_to [E, F] and has a select() with one path
   * following an E-restricted dep and the other path following an F-restricted dep, then when the
   * build chooses the F path the current rule has [E] refined to [] and D2 is the culprit.
   *
   * <p>If the given environment was not refined away for this rule, returns null.
   *
   * <p>See {@link ConstraintSemantics} class documentation for more details on refinement.
   */
  LabelAndLocation getRemovedEnvironmentCulprit(Label environment);
}
