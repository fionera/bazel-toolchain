# Copyright 2018 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "//toolchain/internal:common.bzl",
    _arch = "arch",
    _canonical_dir_path = "canonical_dir_path",
    _check_os_arch_keys = "check_os_arch_keys",
    _host_os_arch_dict_value = "host_os_arch_dict_value",
    _host_tool_features = "host_tool_features",
    _host_tools = "host_tools",
    _list_to_string = "list_to_string",
    _os = "os",
    _os_arch_pair = "os_arch_pair",
    _os_bzl = "os_bzl",
    _pkg_name_from_label = "pkg_name_from_label",
    _pkg_path_from_label = "pkg_path_from_label",
    _supported_targets = "SUPPORTED_TARGETS",
    _toolchain_tools = "toolchain_tools",
)
load(
    "//toolchain/internal:sysroot.bzl",
    _default_sysroot_path = "default_sysroot_path",
    _sysroot_paths_dict = "sysroot_paths_dict",
)
load(
    "//toolchain:aliases.bzl",
    _aliased_libs = "aliased_libs",
    _aliased_tools = "aliased_tools",
)

def _include_dirs_str(rctx, key):
    dirs = rctx.attr.cxx_builtin_include_directories.get(key)
    if not dirs:
        return ""
    return ("\n" + 12 * " ").join(["\"%s\"," % d for d in dirs])

def llvm_config_impl(rctx):
    _check_os_arch_keys(rctx.attr.sysroot)
    _check_os_arch_keys(rctx.attr.cxx_builtin_include_directories)

    os = _os(rctx)
    if os == "windows":
        rctx.file("BUILD.bazel")
        rctx.file("toolchains.bzl", """\
def llvm_register_toolchains():
    pass
""")
        return
    arch = _arch(rctx)

    (key, toolchain_root) = _host_os_arch_dict_value(rctx, "toolchain_roots")
    if not toolchain_root:
        fail("LLVM toolchain root missing for ({}, {})", os, arch)
    (key, llvm_version) = _host_os_arch_dict_value(rctx, "llvm_versions")
    if not llvm_version:
        fail("LLVM version string missing for ({}, {})", os, arch)

    config_repo_path = "external/%s/" % rctx.name

    use_absolute_paths_llvm = rctx.attr.absolute_paths
    use_absolute_paths_sysroot = use_absolute_paths_llvm

    # Check if the toolchain root is a system path.
    system_llvm = False
    if toolchain_root[0] == "/" and (len(toolchain_root) == 1 or toolchain_root[1] != "/"):
        use_absolute_paths_llvm = True
        system_llvm = True

    # Paths for LLVM distribution:
    if system_llvm:
        llvm_dist_path_prefix = _canonical_dir_path(toolchain_root)
    else:
        llvm_dist_label = Label(toolchain_root + ":BUILD.bazel")  # Exact target does not matter.
        if use_absolute_paths_llvm:
            llvm_dist_path_prefix = _canonical_dir_path(str(rctx.path(llvm_dist_label).dirname))
        else:
            llvm_dist_path_prefix = _pkg_path_from_label(llvm_dist_label)

    if not use_absolute_paths_llvm:
        llvm_dist_rel_path = _canonical_dir_path("../../" + llvm_dist_path_prefix)
        llvm_dist_label_prefix = toolchain_root + ":"

        # tools can only be defined as absolute paths or in a subdirectory of
        # config_repo_path, because their paths are relative to the package
        # defining cc_toolchain, and cannot contain '..'.
        # https://github.com/bazelbuild/bazel/issues/7746.  To work around
        # this, we symlink the needed tools under the package so that they (except
        # clang) can be called with normalized relative paths. For clang
        # however, using a path with symlinks interferes with the header file
        # inclusion validation checks, because clang frontend will infer the
        # InstalledDir to be the symlinked path, and will look for header files
        # in the symlinked path, but that seems to fail the inclusion
        # validation check. So we always use a cc_wrapper (which is called
        # through a normalized relative path), and then call clang with the not
        # symlinked path from the wrapper.
        wrapper_bin_prefix = "bin/"
        tools_path_prefix = "bin/"
        for tool_name in _toolchain_tools:
            rctx.symlink(llvm_dist_rel_path + "bin/" + tool_name, tools_path_prefix + tool_name)
        symlinked_tools_str = "".join([
            "\n" + (" " * 8) + "\"" + tools_path_prefix + name + "\","
            for name in _toolchain_tools
        ])
    else:
        llvm_dist_rel_path = llvm_dist_path_prefix
        llvm_dist_label_prefix = llvm_dist_path_prefix

        # Path to individual tool binaries.
        # No symlinking necessary when using absolute paths.
        wrapper_bin_prefix = "bin/"
        tools_path_prefix = llvm_dist_path_prefix + "bin/"
        symlinked_tools_str = ""

    sysroot_paths_dict, sysroot_labels_dict = _sysroot_paths_dict(
        rctx,
        rctx.attr.sysroot,
        use_absolute_paths_sysroot,
    )
    default_sysroot_path = _default_sysroot_path(rctx, os)

    workspace_name = rctx.name
    toolchain_info = struct(
        os = os,
        arch = arch,
        llvm_dist_label_prefix = llvm_dist_label_prefix,
        llvm_dist_path_prefix = llvm_dist_path_prefix,
        tools_path_prefix = tools_path_prefix,
        wrapper_bin_prefix = wrapper_bin_prefix,
        sysroot_paths_dict = sysroot_paths_dict,
        sysroot_labels_dict = sysroot_labels_dict,
        default_sysroot_path = default_sysroot_path,
        target_settings_dict = rctx.attr.target_settings,
        additional_include_dirs_dict = rctx.attr.cxx_builtin_include_directories,
        stdlib_dict = rctx.attr.stdlib,
        cxx_standard_dict = rctx.attr.cxx_standard,
        compile_flags_dict = rctx.attr.compile_flags,
        cxx_flags_dict = rctx.attr.cxx_flags,
        link_flags_dict = rctx.attr.link_flags,
        link_libs_dict = rctx.attr.link_libs,
        opt_compile_flags_dict = rctx.attr.opt_compile_flags,
        opt_link_flags_dict = rctx.attr.opt_link_flags,
        dbg_compile_flags_dict = rctx.attr.dbg_compile_flags,
        coverage_compile_flags_dict = rctx.attr.coverage_compile_flags,
        coverage_link_flags_dict = rctx.attr.coverage_link_flags,
        unfiltered_compile_flags_dict = rctx.attr.unfiltered_compile_flags,
        llvm_version = llvm_version,
    )
    host_dl_ext = "dylib" if os == "darwin" else "so"
    host_tools_info = dict([
        pair
        for (key, tool_path, features) in [
            # This is used for macOS hosts:
            ("libtool", "/usr/bin/libtool", [_host_tool_features.SUPPORTS_ARG_FILE]),
            # This is used with old (pre 7) LLVM versions:
            ("strip", "/usr/bin/strip", []),
            # This is used when lld doesn't support the target platform (i.e.
            # Mach-O for macOS):
            ("ld", "/usr/bin/ld", []),
        ]
        for pair in _host_tools.get_tool_info(rctx, tool_path, features, key).items()
    ])
    cc_toolchains_str, toolchain_labels_str = _cc_toolchains_str(
        workspace_name,
        toolchain_info,
        use_absolute_paths_llvm,
        host_tools_info,
    )

    convenience_targets_str = _convenience_targets_str(
        rctx,
        use_absolute_paths_llvm,
        llvm_dist_rel_path,
        llvm_dist_label_prefix,
        host_dl_ext,
    )

    # Convenience macro to register all generated toolchains.
    rctx.template(
        "toolchains.bzl",
        Label("//toolchain:toolchains.bzl.tpl"),
        {
            "%{toolchain_labels}": toolchain_labels_str,
        },
    )

    # BUILD file with all the generated toolchain definitions.
    rctx.template(
        "BUILD.bazel",
        Label("//toolchain:BUILD.toolchain.tpl"),
        {
            "%{cc_toolchain_config_bzl}": str(rctx.attr._cc_toolchain_config_bzl),
            "%{cc_toolchains}": cc_toolchains_str,
            "%{symlinked_tools}": symlinked_tools_str,
            "%{wrapper_bin_prefix}": wrapper_bin_prefix,
            "%{convenience_targets}": convenience_targets_str,
        },
    )

    # CC wrapper script; see comments near the definition of `wrapper_bin_prefix`.
    if os == "darwin":
        cc_wrapper_tpl = "//toolchain:osx_cc_wrapper.sh.tpl"
    else:
        cc_wrapper_tpl = "//toolchain:cc_wrapper.sh.tpl"
    rctx.template(
        "bin/cc_wrapper.sh",
        Label(cc_wrapper_tpl),
        {
            "%{toolchain_path_prefix}": llvm_dist_path_prefix,
        },
    )

    # libtool wrapper; used if the host libtool doesn't support arg files:
    rctx.template(
        "bin/host_libtool_wrapper.sh",
        Label("//toolchain:host_libtool_wrapper.sh.tpl"),
        {
            "%{libtool_path}": "/usr/bin/libtool",
        },
    )

def _cc_toolchains_str(
        workspace_name,
        toolchain_info,
        use_absolute_paths_llvm,
        host_tools_info):
    # Since all the toolchains rely on downloading the right LLVM toolchain for
    # the host architecture, we don't need to explicitly specify
    # `exec_compatible_with` attribute. If the host and execution platform are
    # not the same, then host auto-detection based LLVM download does not work
    # and the user has to explicitly specify the distribution of LLVM they
    # want.

    # Note that for cross-compiling, the toolchain configuration will need
    # appropriate sysroots. A recommended approach is to configure two
    # `llvm_toolchain` repos, one without sysroots (for easy single platform
    # builds) and register this one, and one with sysroots and provide
    # `--extra_toolchains` flag when cross-compiling.

    cc_toolchains_str = ""
    toolchain_names = []
    for (target_os, target_arch) in _supported_targets:
        suffix = "{}-{}".format(target_arch, target_os)
        cc_toolchain_str = _cc_toolchain_str(
            suffix,
            target_os,
            target_arch,
            toolchain_info,
            use_absolute_paths_llvm,
            host_tools_info,
        )
        if cc_toolchain_str:
            cc_toolchains_str = cc_toolchains_str + cc_toolchain_str
            toolchain_name = "@{}//:cc-toolchain-{}".format(workspace_name, suffix)
            toolchain_names.append(toolchain_name)

    sep = ",\n" + " " * 8  # 2 tabs with tabstop=4.
    toolchain_labels_str = sep.join(["\"{}\"".format(d) for d in toolchain_names])
    return cc_toolchains_str, toolchain_labels_str

# Gets a value from the dict for the target pair, falling back to an empty
# key, if present.  Bazel 4.* doesn't support nested skylark functions, so
# we cannot simplify _dict_value() by defining it as a nested function.
def _dict_value(d, target_pair, default = None):
    return d.get(target_pair, d.get("", default))

def _cc_toolchain_str(
        suffix,
        target_os,
        target_arch,
        toolchain_info,
        use_absolute_paths_llvm,
        host_tools_info):
    host_os = toolchain_info.os
    host_arch = toolchain_info.arch

    host_os_bzl = _os_bzl(host_os)
    target_os_bzl = _os_bzl(target_os)

    target_pair = _os_arch_pair(target_os, target_arch)

    sysroot_path = toolchain_info.sysroot_paths_dict.get(target_pair)
    sysroot_label = toolchain_info.sysroot_labels_dict.get(target_pair)
    if sysroot_label:
        sysroot_label_str = "\"%s\"" % str(sysroot_label)
    else:
        sysroot_label_str = ""

    if not sysroot_path:
        if host_os == target_os and host_arch == target_arch:
            # For darwin -> darwin, we can use the macOS SDK path.
            sysroot_path = toolchain_info.default_sysroot_path
        else:
            # We are trying to cross-compile without a sysroot, let's bail.
            # TODO: Are there situations where we can continue?
            return ""

    extra_files_str = "\":internal-use-files\""

    # `struct` isn't allowed in `BUILD` files so we JSON encode + decode to turn
    # them into `dict`s.
    host_tools_info = json.decode(json.encode(host_tools_info))

    template = """
# CC toolchain for cc-clang-{suffix}.

cc_toolchain_config(
    name = "local-{suffix}",
    host_arch = "{host_arch}",
    host_os = "{host_os}",
    target_arch = "{target_arch}",
    target_os = "{target_os}",
    toolchain_path_prefix = "{llvm_dist_path_prefix}",
    tools_path_prefix = "{tools_path_prefix}",
    wrapper_bin_prefix = "{wrapper_bin_prefix}",
    compiler_configuration = {{
      "additional_include_dirs": {additional_include_dirs},
      "sysroot_path": "{sysroot_path}",
      "stdlib": "{stdlib}",
      "cxx_standard": "{cxx_standard}",
      "compile_flags": {compile_flags},
      "cxx_flags": {cxx_flags},
      "link_flags": {link_flags},
      "link_libs": {link_libs},
      "opt_compile_flags": {opt_compile_flags},
      "opt_link_flags": {opt_link_flags},
      "dbg_compile_flags": {dbg_compile_flags},
      "coverage_compile_flags": {coverage_compile_flags},
      "coverage_link_flags": {coverage_link_flags},
      "unfiltered_compile_flags": {unfiltered_compile_flags},
    }},
    llvm_version = "{llvm_version}",
    host_tools_info = {host_tools_info},
)

toolchain(
    name = "cc-toolchain-{suffix}",
    exec_compatible_with = [
        "@platforms//cpu:{host_arch}",
        "@platforms//os:{host_os_bzl}",
    ],
    target_compatible_with = [
        "@platforms//cpu:{target_arch}",
        "@platforms//os:{target_os_bzl}",
    ],
    target_settings = {target_settings},
    toolchain = ":cc-clang-{suffix}",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
)
"""

    template = template + """
filegroup(
    name = "sysroot-components-{suffix}",
    srcs = [{sysroot_label_str}],
)
"""

    if use_absolute_paths_llvm:
        template = template + """
filegroup(
    name = "compiler-components-{suffix}",
    srcs = [":sysroot-components-{suffix}"],
)

filegroup(
    name = "linker-components-{suffix}",
    srcs = [":sysroot-components-{suffix}"],
)

filegroup(
    name = "all-components-{suffix}",
    srcs = [
        ":compiler-components-{suffix}",
        ":linker-components-{suffix}",
    ],
)

filegroup(name = "all-files-{suffix}", srcs = [":all-components-{suffix}", {extra_files_str}])
filegroup(name = "archiver-files-{suffix}", srcs = [{extra_files_str}])
filegroup(name = "assembler-files-{suffix}", srcs = [{extra_files_str}])
filegroup(name = "compiler-files-{suffix}", srcs = [":compiler-components-{suffix}", {extra_files_str}])
filegroup(name = "dwp-files-{suffix}", srcs = [{extra_files_str}])
filegroup(name = "linker-files-{suffix}", srcs = [":linker-components-{suffix}", {extra_files_str}])
filegroup(name = "objcopy-files-{suffix}", srcs = [{extra_files_str}])
filegroup(name = "strip-files-{suffix}", srcs = [{extra_files_str}])
"""
    else:
        template = template + """
filegroup(
    name = "compiler-components-{suffix}",
    srcs = [
        "{llvm_dist_label_prefix}clang",
        "{llvm_dist_label_prefix}include",
        ":sysroot-components-{suffix}",
    ],
)

filegroup(
    name = "linker-components-{suffix}",
    srcs = [
        "{llvm_dist_label_prefix}clang",
        "{llvm_dist_label_prefix}ld",
        "{llvm_dist_label_prefix}ar",
        "{llvm_dist_label_prefix}lib",
        ":sysroot-components-{suffix}",
    ],
)

filegroup(
    name = "all-components-{suffix}",
    srcs = [
        "{llvm_dist_label_prefix}bin",
        ":compiler-components-{suffix}",
        ":linker-components-{suffix}",
    ],
)

filegroup(name = "all-files-{suffix}", srcs = [":all-components-{suffix}", {extra_files_str}])
filegroup(name = "archiver-files-{suffix}", srcs = ["{llvm_dist_label_prefix}ar", {extra_files_str}])
filegroup(name = "assembler-files-{suffix}", srcs = ["{llvm_dist_label_prefix}as", {extra_files_str}])
filegroup(name = "compiler-files-{suffix}", srcs = [":compiler-components-{suffix}", {extra_files_str}])
filegroup(name = "dwp-files-{suffix}", srcs = ["{llvm_dist_label_prefix}dwp", {extra_files_str}])
filegroup(name = "linker-files-{suffix}", srcs = [":linker-components-{suffix}", {extra_files_str}])
filegroup(name = "objcopy-files-{suffix}", srcs = ["{llvm_dist_label_prefix}objcopy", {extra_files_str}])
filegroup(name = "strip-files-{suffix}", srcs = ["{llvm_dist_label_prefix}strip", {extra_files_str}])
"""

    template = template + """
cc_toolchain(
    name = "cc-clang-{suffix}",
    all_files = "all-files-{suffix}",
    ar_files = "archiver-files-{suffix}",
    as_files = "assembler-files-{suffix}",
    compiler_files = "compiler-files-{suffix}",
    dwp_files = "dwp-files-{suffix}",
    linker_files = "linker-files-{suffix}",
    objcopy_files = "objcopy-files-{suffix}",
    strip_files = "strip-files-{suffix}",
    toolchain_config = "local-{suffix}",
)
"""

    return template.format(
        suffix = suffix,
        target_os = target_os,
        target_arch = target_arch,
        host_os = host_os,
        host_arch = host_arch,
        target_settings = _list_to_string(_dict_value(toolchain_info.target_settings_dict, target_pair)),
        target_os_bzl = target_os_bzl,
        host_os_bzl = host_os_bzl,
        llvm_dist_label_prefix = toolchain_info.llvm_dist_label_prefix,
        llvm_dist_path_prefix = toolchain_info.llvm_dist_path_prefix,
        tools_path_prefix = toolchain_info.tools_path_prefix,
        wrapper_bin_prefix = toolchain_info.wrapper_bin_prefix,
        sysroot_label_str = sysroot_label_str,
        sysroot_path = sysroot_path,
        additional_include_dirs = _list_to_string(toolchain_info.additional_include_dirs_dict.get(target_pair, [])),
        stdlib = _dict_value(toolchain_info.stdlib_dict, target_pair, "builtin-libc++"),
        cxx_standard = _dict_value(toolchain_info.cxx_standard_dict, target_pair, "c++17"),
        compile_flags = _list_to_string(_dict_value(toolchain_info.compile_flags_dict, target_pair)),
        cxx_flags = _list_to_string(_dict_value(toolchain_info.cxx_flags_dict, target_pair)),
        link_flags = _list_to_string(_dict_value(toolchain_info.link_flags_dict, target_pair)),
        link_libs = _list_to_string(_dict_value(toolchain_info.link_libs_dict, target_pair)),
        opt_compile_flags = _list_to_string(_dict_value(toolchain_info.opt_compile_flags_dict, target_pair)),
        opt_link_flags = _list_to_string(_dict_value(toolchain_info.opt_link_flags_dict, target_pair)),
        dbg_compile_flags = _list_to_string(_dict_value(toolchain_info.dbg_compile_flags_dict, target_pair)),
        coverage_compile_flags = _list_to_string(_dict_value(toolchain_info.coverage_compile_flags_dict, target_pair)),
        coverage_link_flags = _list_to_string(_dict_value(toolchain_info.coverage_link_flags_dict, target_pair)),
        unfiltered_compile_flags = _list_to_string(_dict_value(toolchain_info.unfiltered_compile_flags_dict, target_pair)),
        llvm_version = toolchain_info.llvm_version,
        extra_files_str = extra_files_str,
        host_tools_info = host_tools_info,
    )

def _convenience_targets_str(rctx, use_absolute_paths, llvm_dist_rel_path, llvm_dist_label_prefix, host_dl_ext):
    if use_absolute_paths:
        llvm_dist_label_prefix = ":"
        filenames = []
        for libname in _aliased_libs:
            filename = "lib/{}.{}".format(libname, host_dl_ext)
            filenames.append(filename)
        for toolname in _aliased_tools:
            filename = "bin/{}".format(toolname)
            filenames.append(filename)

        for filename in filenames:
            rctx.symlink(llvm_dist_rel_path + filename, filename)

    lib_target_strs = []
    for name in _aliased_libs:
        template = """
cc_import(
    name = "{name}",
    shared_library = "{{llvm_dist_label_prefix}}lib/lib{name}.{{host_dl_ext}}",
)""".format(name = name)
        lib_target_strs.append(template)

    tool_target_strs = []
    for name in _aliased_tools:
        template = """
native_binary(
    name = "{name}",
    out = "{name}",
    src = "{{llvm_dist_label_prefix}}bin/{name}",
)""".format(name = name)
        tool_target_strs.append(template)

    return "\n".join(lib_target_strs + tool_target_strs).format(
        llvm_dist_label_prefix = llvm_dist_label_prefix,
        host_dl_ext = host_dl_ext,
    )
