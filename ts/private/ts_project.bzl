"ts_project rule"

load("@aspect_bazel_lib//lib:copy_to_bin.bzl", "copy_files_to_bin_actions")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@aspect_rules_js//js:providers.bzl", "js_info")
load("@aspect_rules_js//js:libs.bzl", "js_lib_helpers")
load(":ts_lib.bzl", "COMPILER_OPTION_ATTRS", "OUTPUT_ATTRS", "STD_ATTRS", "ValidOptionsInfo", _lib = "lib")
load(":ts_config.bzl", "TsConfigInfo")
load(":ts_validate_options.bzl", _validate_lib = "lib")

def _ts_project_impl(ctx):
    """Creates the action which spawns `tsc`.

    This function has two extra arguments that are particular to how it's called
    within build_bazel_rules_nodejs and @bazel/typescript npm package.
    Other TS rule implementations wouldn't need to pass these:

    Args:
        ctx: starlark rule execution context

    Returns:
        list of providers
    """
    srcs = [_lib.relative_to_package(src.path, ctx) for src in ctx.files.srcs]

    # Recalculate outputs inside the rule implementation.
    # The outs are first calculated in the macro in order to try to predetermine outputs so they can be declared as
    # outputs on the rule. This provides the benefit of being able to reference an output file with a label.
    # However, it is not possible to evaluate files in outputs of other rules such as filegroup, therefore the outs are
    # recalculated here.
    typings_out_dir = ctx.attr.declaration_dir or ctx.attr.out_dir
    js_outs = _lib.declare_outputs(ctx, [] if not ctx.attr.transpile else _lib.calculate_js_outs(srcs, ctx.attr.out_dir, ctx.attr.root_dir, ctx.attr.allow_js, ctx.attr.preserve_jsx, ctx.attr.emit_declaration_only))
    map_outs = _lib.declare_outputs(ctx, [] if not ctx.attr.transpile else _lib.calculate_map_outs(srcs, ctx.attr.out_dir, ctx.attr.root_dir, ctx.attr.source_map, ctx.attr.preserve_jsx, ctx.attr.emit_declaration_only))
    typings_outs = _lib.declare_outputs(ctx, _lib.calculate_typings_outs(srcs, typings_out_dir, ctx.attr.root_dir, ctx.attr.declaration, ctx.attr.composite, ctx.attr.allow_js))
    typing_maps_outs = _lib.declare_outputs(ctx, _lib.calculate_typing_maps_outs(srcs, typings_out_dir, ctx.attr.root_dir, ctx.attr.declaration_map, ctx.attr.allow_js))

    arguments = ctx.actions.args()
    execution_requirements = {}
    executable = ctx.executable.tsc

    if ctx.attr.supports_workers:
        # Set to use a multiline param-file for worker mode
        arguments.use_param_file("@%s", use_always = True)
        arguments.set_param_file_format("multiline")
        execution_requirements["supports-workers"] = "1"
        execution_requirements["worker-key-mnemonic"] = "TsProject"
        executable = ctx.executable.tsc_worker

    # Add user specified arguments *before* rule supplied arguments
    arguments.add_all(ctx.attr.args)

    outdir = _lib.join(ctx.label.package, ctx.attr.out_dir) if ctx.attr.out_dir else ctx.label.package
    if outdir == "":
        outdir = "."
    arguments.add_all([
        "--project",
        ctx.file.tsconfig.short_path,
        "--outDir",
        outdir,
        "--rootDir",
        _lib.calculate_root_dir(ctx),
    ])
    if len(typings_outs) > 0:
        declaration_dir = _lib.join(ctx.label.package, typings_out_dir)
        if declaration_dir == "":
            declaration_dir = "."
        arguments.add_all([
            "--declarationDir",
            declaration_dir,
        ])

    # When users report problems, we can ask them to re-build with
    # --define=VERBOSE_LOGS=1
    # so anything that's useful to diagnose rule failures belongs here
    if "VERBOSE_LOGS" in ctx.var.keys():
        arguments.add_all([
            # What files were in the ts.Program
            "--listFiles",
            # Did tsc write all outputs to the place we expect to find them?
            "--listEmittedFiles",
            # Why did module resolution fail?
            "--traceResolution",
            # Why was the build slow?
            "--diagnostics",
            "--extendedDiagnostics",
        ])

    inputs = ctx.files.srcs[:]
    for dep in ctx.attr.deps:
        if ValidOptionsInfo in dep:
            inputs.append(dep[ValidOptionsInfo].marker)

    inputs.extend(js_lib_helpers.gather_files_from_js_providers(
        targets = ctx.attr.srcs + ctx.attr.deps,
        include_transitive_sources = True,
        include_declarations = True,
        include_npm_linked_packages = True,
    ))

    # Gather TsConfig info from both the direct (tsconfig) and indirect (extends) attribute
    tsconfig_inputs = copy_files_to_bin_actions(ctx, _validate_lib.tsconfig_inputs(ctx))
    inputs.extend(tsconfig_inputs)

    # We do not try to predeclare json_outs, because their output locations generally conflict with their path in the source tree.
    # (The exception is when out_dir is used, then the .json output is a different path than the input.)
    # However tsc will copy .json srcs to the output tree so we want to declare these outputs to include along with .js Default outs
    # NB: We don't have emit_declaration_only setting here, so use presence of any JS outputs as an equivalent.
    # tsc will only produce .json if it also produces .js
    if len(js_outs):
        pkg_len = len(ctx.label.package) + 1 if len(ctx.label.package) else 0
        rootdir_replace_pattern = ctx.attr.root_dir + "/" if ctx.attr.root_dir else ""
        json_outs = _lib.declare_outputs(ctx, [
            _lib.join(ctx.attr.out_dir, src.short_path[pkg_len:].replace(rootdir_replace_pattern, ""))
            for src in ctx.files.srcs
            if src.basename.endswith(".json") and src.is_source
        ])
    else:
        json_outs = []

    outputs = json_outs + js_outs + map_outs + typings_outs + typing_maps_outs
    if ctx.outputs.buildinfo_out:
        arguments.add_all([
            "--tsBuildInfoFile",
            ctx.outputs.buildinfo_out.short_path,
        ])
        outputs.append(ctx.outputs.buildinfo_out)
    output_sources = json_outs + js_outs + map_outs
    typings_srcs = [s for s in ctx.files.srcs if _lib.is_typings_src(s.path)]

    if len(js_outs) + len(typings_outs) < 1:
        label = "//{}:{}".format(ctx.label.package, ctx.label.name)
        if len(typings_srcs) > 0:
            no_outs_msg = """ts_project target {target} only has typings in srcs.
Since there is no `tsc` action to perform, there are no generated outputs.

> ts_project doesn't support "typecheck-only"; see https://github.com/aspect-build/rules_ts/issues/88

This should be changed to js_library, which can be done by running:

    buildozer 'new_load @aspect_rules_js//js:defs.bzl js_library' //{pkg}:__pkg__
    buildozer 'set kind js_library' {target}
    buildozer 'remove declaration' {target}

""".format(
                target = label,
                pkg = ctx.label.package,
            )
        elif ctx.attr.transpile:
            no_outs_msg = """ts_project target %s is configured to produce no outputs.

This might be because
- you configured it with `noEmit`
- the `srcs` are empty
- `srcs` has elements producing non-ts outputs
""" % label
        else:
            no_outs_msg = "ts_project target %s with custom transpiler needs 'declaration = True'." % label
        fail(no_outs_msg + """
This is an error because Bazel does not run actions unless their outputs are needed for the requested targets to build.
""")

    output_declarations = typings_outs + typing_maps_outs + typings_srcs

    # Default outputs (DefaultInfo files) is what you see on the command-line for a built
    # library, and determines what files are used by a simple non-provider-aware downstream
    # library. Only the JavaScript outputs are intended for use in non-TS-aware dependents.
    if ctx.attr.transpile:
        # Special case case where there are no source outputs and we don't have a custom
        # transpiler so we add output_declarations to the default outputs
        default_outputs = output_sources[:] if len(output_sources) else output_declarations[:]
    else:
        # We must avoid tsc writing any JS files in this case, as tsc was only run for typings, and some other
        # action will try to write the JS files. We must avoid collisions where two actions write the same file.
        arguments.add("--emitDeclarationOnly")

        # We don't produce any DefaultInfo outputs in this case, because we avoid running the tsc action
        # unless the output_declarations are requested.
        default_outputs = []

    if len(outputs) > 0:
        ctx.actions.run(
            executable = executable,
            inputs = copy_files_to_bin_actions(ctx, inputs),
            arguments = [arguments],
            outputs = outputs,
            mnemonic = "TsProject",
            execution_requirements = execution_requirements,
            progress_message = "Compiling TypeScript project %s [tsc -p %s]" % (
                ctx.label,
                ctx.file.tsconfig.short_path,
            ),
            env = {
                "BAZEL_BINDIR": ctx.bin_dir.path,
            },
        )

    transitive_sources = js_lib_helpers.gather_transitive_sources(output_sources, ctx.attr.srcs + ctx.attr.deps)

    transitive_declarations = js_lib_helpers.gather_transitive_declarations(output_declarations, ctx.attr.srcs + ctx.attr.deps)

    npm_linked_packages = js_lib_helpers.gather_npm_linked_packages(
        srcs = ctx.attr.srcs,
        deps = ctx.attr.deps,
    )

    npm_package_stores = js_lib_helpers.gather_npm_package_stores(
        targets = ctx.attr.data,
    )

    runfiles = js_lib_helpers.gather_runfiles(
        ctx = ctx,
        sources = output_sources,
        data = ctx.attr.data,
        deps = ctx.attr.srcs + ctx.attr.deps,
    )

    providers = [
        DefaultInfo(
            files = depset(default_outputs),
            runfiles = runfiles,
        ),
        js_info(
            declarations = output_declarations,
            npm_linked_packages = npm_linked_packages.direct,
            npm_package_stores = npm_package_stores.direct,
            sources = output_sources,
            transitive_declarations = transitive_declarations,
            transitive_npm_linked_packages = npm_linked_packages.transitive,
            transitive_npm_package_stores = npm_package_stores.transitive,
            transitive_sources = transitive_sources,
        ),
        TsConfigInfo(deps = depset(tsconfig_inputs, transitive = [
            dep[TsConfigInfo].deps
            for dep in ctx.attr.deps
            if TsConfigInfo in dep
        ])),
        OutputGroupInfo(
            types = depset(output_declarations),
        ),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
            extensions = ["ts", "tsx"],
        ),
    ]

    return providers

ts_project = struct(
    implementation = _ts_project_impl,
    attrs = dicts.add(COMPILER_OPTION_ATTRS, STD_ATTRS, OUTPUT_ATTRS),
)
