from pathlib import Path
import sys

source = Path(sys.argv[1]) / "source3" / "wscript"
# Bionic's generated Linux UAPI header omits the inline speed helper.
interfaces = Path(sys.argv[1]) / "lib" / "socket" / "interfaces.c"
interfaces_text = interfaces.read_text(encoding="utf-8")
interfaces_old = "\t*speed = ((uint64_t)ethtool_cmd_speed(&ecmd)) * 1000 * 1000;"
interfaces_new = "#ifdef __ANDROID__\n\t*speed = (((uint64_t)ecmd.speed_hi << 16) | ecmd.speed) * 1000 * 1000;\n#else\n" + interfaces_old + "\n#endif"
if interfaces_new not in interfaces_text:
    if interfaces_old not in interfaces_text:
        raise SystemExit('Expected ethtool speed query was not found')
    interfaces.write_text(interfaces_text.replace(interfaces_old, interfaces_new, 1), encoding="utf-8")
text = source.read_text(encoding="utf-8")
dumpcore = Path(sys.argv[1]) / "source3" / "lib" / "dumpcore.c"
dumpcore_text = dumpcore.read_text(encoding="utf-8")
# umask uses only the low nine permission bits; Bionic rejects other bits.
dumpcore.write_text(dumpcore_text.replace("umask(~(0700));", "umask(0077);"), encoding="utf-8")
old = "    seteuid = False\n\n#\n# Ensure we select the correct set of system calls on Linux.\n#"
new = "    # Android arm64 is Linux and uses Linux per-thread credential syscalls.\n    # The generic runtime probe cannot accurately select this path under Bionic.\n    seteuid = True\n    conf.DEFINE('HAVE_LINUX_THREAD_CREDENTIALS', 1)\n\n#\n# Ensure we select the correct set of system calls on Linux.\n#"

if new in text:
    print("Android credential patch already applied")
elif old in text:
    source.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Applied Android Linux credential selection")
else:
    raise SystemExit(f"Expected Samba credential probe block was not found in {source}")

# Host Heimdal code generators share replace.h with the Android target build.
# Do not include Linux kernel headers when compiling these tools for MSYS.
replace_header = Path(sys.argv[1]) / "lib" / "replace" / "replace.h"
replace_text = replace_header.read_text(encoding="utf-8")
old_linux_types = "#ifdef HAVE_LINUX_TYPES_H\n/*\n * This is needed as some broken header files require this to be included early\n */\n#include <linux/types.h>\n#endif"
new_linux_types = "#if defined(HAVE_LINUX_TYPES_H) && !defined(_SAMBA_HOSTCC_)\n/*\n * This is needed as some broken header files require this to be included early\n */\n#include <linux/types.h>\n#endif"
if new_linux_types in replace_text:
    print("Host compiler Linux header guard already applied")
elif old_linux_types in replace_text:
    replace_header.write_text(replace_text.replace(old_linux_types, new_linux_types, 1), encoding="utf-8")
    print("Applied host compiler Linux header guard")
else:
    raise SystemExit(f"Expected Linux types include block was not found in {replace_header}")

def guard_host_header(path, macro, include_line):
    p = Path(sys.argv[1]) / path
    content = p.read_text(encoding="utf-8")
    old = f"#ifdef {macro}\n{include_line}"
    new = f"#if defined({macro}) && !defined(_SAMBA_HOSTCC_)\n{include_line}"
    if new in content:
        return
    if old not in content:
        if macro not in content:
            return
        raise SystemExit(f"Expected {macro} include block was not found in {p}")
    p.write_text(content.replace(old, new, 1), encoding="utf-8")

guard_host_header("lib/replace/system/filesys.h", "HAVE_LINUX_OPENAT2_H", "#include <linux/openat2.h>")
for roken_header in ("third_party/heimdal/lib/roken/roken.h.in", "third_party/heimdal_build/roken.h"):
    guard_host_header(roken_header, "HAVE_NETINET_IN6_H", "#include <netinet/in6.h>")
for auxv_source in ("third_party/heimdal/lib/roken/issuid.c", "third_party/heimdal/lib/roken/getauxval.c"):
    guard_host_header(auxv_source, "HAVE_SYS_AUXV_H", "#include <sys/auxv.h>")
guard_host_header("third_party/heimdal/lib/roken/getauxval.h", "HAVE_SYS_AUXV_H", "#include <sys/auxv.h>")
guard_host_header("lib/replace/replace.c", "HAVE_SYS_SYSCALL_H", "#include <sys/syscall.h>")
guard_host_header("lib/replace/replace.c", "HAVE_SYS_PRCTL_H", "#include <sys/prctl.h>")
getauxval_source = Path(sys.argv[1]) / "third_party" / "heimdal" / "lib" / "roken" / "getauxval.c"
getauxval_text = getauxval_source.read_text(encoding="utf-8")
getauxval_text = getauxval_text.replace("#ifdef HAVE_GETAUXVAL\n", "#if defined(HAVE_GETAUXVAL) && !defined(_SAMBA_HOSTCC_)\n")
getauxval_source.write_text(getauxval_text, encoding="utf-8")
replace_source = Path(sys.argv[1]) / "lib" / "replace" / "replace.c"
replace_source_text = replace_source.read_text(encoding="utf-8")
for macro in ("HAVE_SYSCALL_COPY_FILE_RANGE", "HAVE_LINUX_IOCTL"):
    replace_source_text = replace_source_text.replace(f"#ifdef {macro}\n", f"#if defined({macro}) && !defined(_SAMBA_HOSTCC_)\n")
    replace_source_text = replace_source_text.replace(f"# ifdef {macro}\n", f"# if defined({macro}) && !defined(_SAMBA_HOSTCC_)\n")
replace_source.write_text(replace_source_text, encoding="utf-8")

# MSYS Python can emit Windows absolute dependency paths containing '..'. Waf's
# gccdeps path walker cannot resolve those components, despite the file existing.
gccdeps = Path(sys.argv[1]) / "third_party" / "waf" / "waflib" / "extras" / "gccdeps.py"
gcc_text = gccdeps.read_text(encoding="utf-8")
old_path_lookup = "\t\tif os.path.isabs(path):\n\t\t\tnode = path_to_node(bld.root, path, cached_nodes)"
intermediate_path_lookup = "\t\tif os.path.isabs(path):\n\t\t\tpath = os.path.normpath(path)\n\t\t\tnode = path_to_node(bld.root, path, cached_nodes)"
new_path_lookup = intermediate_path_lookup + "\n\t\t\tif not node and re.match(r'^[A-Za-z]:[\\\\/]', path):\n\t\t\t\tmsys_path = '/' + path[0].lower() + path[2:].replace('\\\\', '/')\n\t\t\t\tbase_node = bld.srcnode\n\t\t\t\twhile base_node:\n\t\t\t\t\tbase_path = base_node.abspath()\n\t\t\t\t\tif re.match(r'^[A-Za-z]:[\\\\/]', base_path):\n\t\t\t\t\t\tbase_path = '/' + base_path[0].lower() + base_path[2:].replace('\\\\', '/')\n\t\t\t\t\trel_path = os.path.relpath(msys_path, base_path)\n\t\t\t\t\tif rel_path != '..' and not rel_path.startswith('..' + os.sep):\n\t\t\t\t\t\tnode = base_node.find_node(rel_path)\n\t\t\t\t\t\tif node:\n\t\t\t\t\t\t\tbreak\n\t\t\t\t\tbase_node = base_node.parent"
if new_path_lookup in gcc_text:
    print("Waf absolute dependency path normalization already applied")
elif intermediate_path_lookup in gcc_text or old_path_lookup in gcc_text:
    previous = intermediate_path_lookup if intermediate_path_lookup in gcc_text else old_path_lookup
    gccdeps.write_text(gcc_text.replace(previous, new_path_lookup, 1), encoding="utf-8")
    print("Applied Waf absolute dependency path normalization")
else:
    raise SystemExit(f"Expected Waf gccdeps path lookup was not found in {gccdeps}")

# Targeted Waf builds still post unrelated Samba binary generators. Do not try
# to expose a symlink for an unrelated executable that this target did not build.
installer = Path(sys.argv[1]) / "buildtools" / "wafsamba" / "samba_install.py"
install_text = installer.read_text(encoding="utf-8")
old_symlink = "    binpath = self.link_task.outputs[0].abspath(self.env)\n    bldpath = os.path.join(self.bld.env.BUILD_DIRECTORY, self.link_task.outputs[0].name)"
new_symlink = "    binpath = self.link_task.outputs[0].abspath(self.env)\n    if not os.path.exists(binpath):\n        return\n    bldpath = os.path.join(self.bld.env.BUILD_DIRECTORY, self.link_task.outputs[0].name)"
if new_symlink in install_text:
    print("Waf targeted binary symlink guard already applied")
elif old_symlink in install_text:
    installer.write_text(install_text.replace(old_symlink, new_symlink, 1), encoding="utf-8")
    print("Applied Waf targeted binary symlink guard")
else:
    raise SystemExit(f"Expected Waf binary symlink block was not found in {installer}")
install_text = installer.read_text(encoding="utf-8")
old_lib_symlink = "    link_target = os.path.join(blddir, link_target)\n\n    if os.path.lexists(link_target):"
new_lib_symlink = "    link_target = os.path.join(blddir, link_target)\n\n    if not os.path.exists(libpath):\n        return\n\n    if os.path.lexists(link_target):"
if new_lib_symlink in install_text:
    print("Waf targeted library symlink guard already applied")
elif old_lib_symlink in install_text:
    installer.write_text(install_text.replace(old_lib_symlink, new_lib_symlink, 1), encoding="utf-8")
    print("Applied Waf targeted library symlink guard")
else:
    raise SystemExit(f"Expected Waf library symlink block was not found in {installer}")

# Samba records --hostcc but does not apply it to task-generator compiler envs
# MSYS resolves extensionless PE paths to .exe, which makes POSIX symlink
# replacement ambiguous. Publish host tools as explicit .exe copies instead.
install_text = installer.read_text(encoding="utf-8")
host_publish_anchor = "    bldpath = os.path.join(self.bld.env.BUILD_DIRECTORY, self.link_task.outputs[0].name)\n"
host_publish_patch = host_publish_anchor + "\n    if getattr(self, 'samba_use_hostcc', False) and os.path.exists(binpath + '.exe'):\n        import shutil\n        if os.path.lexists(bldpath):\n            os.unlink(bldpath)\n        shutil.copyfile(binpath + '.exe', bldpath + '.exe')\n        return\n"
if "shutil.copyfile(binpath + '.exe', bldpath + '.exe')" not in install_text:
    if host_publish_anchor not in install_text:
        raise SystemExit('Expected host binary publish block was not found')
    installer.write_text(install_text.replace(host_publish_anchor, host_publish_patch, 1), encoding="utf-8")

install_text = installer.read_text(encoding="utf-8")
install_text = install_text.replace("getattr(self, 'samba_use_hostcc', False) and os.path.exists(binpath + '.exe')", "(getattr(self, 'samba_use_hostcc', False) or self.name in ('compile_et', 'asn1_compile')) and os.path.exists(binpath + '.exe')")
installer.write_text(install_text, encoding="utf-8")

# Samba records --hostcc but does not apply it to task-generator compiler envs
# in this cross-build setup. Bind it only to targets explicitly marked hostcc.
wafsamba = Path(sys.argv[1]) / "buildtools" / "wafsamba" / "wafsamba.py"
waf_text = wafsamba.read_text(encoding="utf-8")
subsystem_anchor = "        samba_builtin_subsystem = None,\n        )\n\n    if cflags_end is not None:"
subsystem_patched = "        samba_builtin_subsystem = None,\n        )\n\n    if use_hostcc and bld.env.HOSTCC:\n        t.env = t.env.derive()\n        t.env.CC = Utils.to_list(bld.env.HOSTCC)\n        t.env.LINK_CC = Utils.to_list(bld.env.HOSTCC)\n\n    if cflags_end is not None:"
binary_anchor = "        samba_ldflags  = pie_ldflags\n        )\n\n    if manpages is not None"
binary_patched = "        samba_ldflags  = pie_ldflags\n        )\n\n    if use_hostcc and bld.env.HOSTCC:\n        t.env = t.env.derive()\n        t.env.CC = Utils.to_list(bld.env.HOSTCC)\n        t.env.LINK_CC = Utils.to_list(bld.env.HOSTCC)\n\n    if manpages is not None"
if subsystem_patched in waf_text and binary_patched in waf_text:
    print("Waf host compiler selection already applied")
elif subsystem_anchor in waf_text and binary_anchor in waf_text:
    waf_text = waf_text.replace(subsystem_anchor, subsystem_patched, 1)
    waf_text = waf_text.replace(binary_anchor, binary_patched, 1)
    wafsamba.write_text(waf_text, encoding="utf-8")
    print("Applied Waf host compiler selection for Heimdal tools")
else:
    raise SystemExit(f"Expected Samba task-generator compiler blocks were not found in {wafsamba}")

# Bionic returns NULL password/gecos for built-in Android accounts.
# Keep the password field locked; never turn absent password data into empty auth.
passwd_source = Path(sys.argv[1]) / 'lib/util/util_pw.c'
passwd_text = passwd_source.read_text(encoding='utf-8')
for field, fallback in [('pw_passwd', '*'), ('pw_gecos', '')]:
    expression = f'(from->{field} != NULL ? from->{field} : "{fallback}")'
    passwd_text = passwd_text.replace(f'strlen(from->{field})', f'strlen({expression})')
    passwd_text = passwd_text.replace(f'talloc_strdup(ret, from->{field})', f'talloc_strdup(ret, {expression})')
passwd_source.write_text(passwd_text, encoding='utf-8')

# A static RPC worker pulls both smbd_base and RPC_NCACN_NP into one ELF.
# Reuse the subsystem instead of compiling rpc_ncacn_np.c twice.
server_build = Path(sys.argv[1]) / 'source3/wscript_build'
server_text = server_build.read_text(encoding='utf-8')
duplicate = '                          rpc_server/rpc_ncacn_np.c\n'
if duplicate in server_text:
    server_text = server_text.replace(duplicate, '', 1)
    anchor = "''' + NOTIFY_SOURCES + SMB1_SOURCES,\n                   deps='''"
    if anchor not in server_text:
        raise SystemExit('Missing smbd_base dependency anchor')
    server_text = server_text.replace(anchor, anchor + '\n                        RPC_NCACN_NP_TRANSPORT', 1)
    server_build.write_text(server_text, encoding='utf-8')
server_text = server_text.replace('                        RPC_NCACN_NP\n', '                        RPC_NCACN_NP_TRANSPORT\n')
server_build.write_text(server_text, encoding='utf-8')
rpc_build = Path(sys.argv[1]) / 'source3/rpc_server/wscript_build'
rpc_text = rpc_build.read_text(encoding='utf-8')
rpc_old = "bld.SAMBA3_SUBSYSTEM('RPC_NCACN_NP',\n                    source='rpc_ncacn_np.c rpc_handles.c',\n                    deps='auth common_auth npa_tstream')"
rpc_new = "bld.SAMBA3_SUBSYSTEM('RPC_NCACN_NP_TRANSPORT',\n                    source='rpc_ncacn_np.c',\n                    deps='auth common_auth npa_tstream')\n\nbld.SAMBA3_SUBSYSTEM('RPC_NCACN_NP',\n                    source='rpc_handles.c',\n                    deps='RPC_NCACN_NP_TRANSPORT dcerpc-server-core')"
if rpc_new not in rpc_text:
    if rpc_old not in rpc_text:
        raise SystemExit('Missing RPC_NCACN_NP source anchor')
    rpc_build.write_text(rpc_text.replace(rpc_old, rpc_new, 1), encoding='utf-8')

# The module keeps RPC helpers beside smbd; Android has no /usr/local/samba.
dynconfig = Path(sys.argv[1]) / 'dynconfig/dynconfig.c'
dyntext = dynconfig.read_text(encoding='utf-8')
dyn_anchor = 'DEFINE_DYN_CONFIG_PARAM(SAMBA_LIBEXECDIR)'
dyn_patch = '#if defined(__ANDROID__)\n#undef SAMBA_LIBEXECDIR\n#define SAMBA_LIBEXECDIR "/data/adb/modules/smbdwebui/bin"\n#endif\n' + dyn_anchor
if dyn_patch not in dyntext:
    if dyn_anchor not in dyntext:
        raise SystemExit('Missing Samba libexec path anchor')
    dynconfig.write_text(dyntext.replace(dyn_anchor, dyn_patch, 1), encoding='utf-8')

# Also use an Android default before command-line/config log overrides load.
dyntext = dynconfig.read_text(encoding='utf-8')
log_anchor = 'DEFINE_DYN_CONFIG_PARAM(LOGFILEBASE)'
log_patch = '#if defined(__ANDROID__)\n#undef LOGFILEBASE\n#define LOGFILEBASE "/data/adb/smbdwebui/runtime/log"\n#endif\n' + log_anchor
if log_patch not in dyntext:
    if log_anchor not in dyntext:
        raise SystemExit('Missing Samba default log path anchor')
    dynconfig.write_text(dyntext.replace(log_anchor, log_patch, 1), encoding='utf-8')

# Fully static Android programs: include Bionic, libdl and zlib as archives.
# The host generators and configure probes retain their own linking mode.
waf_text = wafsamba.read_text(encoding="utf-8")
static_anchor = "    # first create a target for building the object files for this binary\n"
old_static_condition = "    if binname == 'client/smbclient':"
static_condition = "    if binname in ('client/smbclient', 'smbd/smbd', 'samba-dcerpcd', 'rpcd_classic', 'rpcd_lsad', 'rpcd_winreg'):"
waf_text = waf_text.replace(old_static_condition, static_condition)
waf_text = waf_text.replace("pie_ldflags.extend(['-static', '-no-pie'])", "pie_ldflags.extend(['-static', '-no-pie', '-Wl,--gc-sections', '-Wl,--icf=safe'])")
static_patch = static_condition + "\n        pie_ldflags = [flag for flag in pie_ldflags if flag != '-pie']\n        pie_ldflags.extend(['-static', '-no-pie', '-Wl,--gc-sections', '-Wl,--icf=safe'])\n\n" + static_anchor
wafsamba.write_text(waf_text, encoding="utf-8")
if static_patch not in waf_text:
    if static_anchor not in waf_text:
        raise SystemExit('Expected Samba binary linker flags block was not found')
    wafsamba.write_text(waf_text.replace(static_anchor, static_patch, 1), encoding="utf-8")

# Bionic's static libdl does not implement dlopen. Use Samba's own portable
# fallback and its built-in module registration for the static Android build.
replace_text = replace_header.read_text(encoding="utf-8")
dl_anchor = '#include "config.h"\n#endif\n'
dl_patch = dl_anchor + '\n#ifdef __ANDROID__\n#undef HAVE_DLOPEN\n#undef HAVE_DLSYM\n#undef HAVE_DLERROR\n#undef HAVE_DLCLOSE\n#endif\n'
if dl_patch not in replace_text:
    if dl_anchor not in replace_text:
        raise SystemExit('Expected replace.h config include was not found')
    replace_header.write_text(replace_text.replace(dl_anchor, dl_patch, 1), encoding="utf-8")
replace_wscript = Path(sys.argv[1]) / 'lib' / 'replace' / 'wscript'
replace_wscript_text = replace_wscript.read_text(encoding='utf-8')
dl_source_old = "    if not bld.CONFIG_SET('HAVE_DLOPEN'):        REPLACE_SOURCE += ' dlfcn.c'"
dl_source_new = "    REPLACE_SOURCE += ' dlfcn.c'  # Also supplies static Android loader fallbacks."
if dl_source_new not in replace_wscript_text:
    if dl_source_old not in replace_wscript_text:
        raise SystemExit('Expected libreplace dlfcn source selection was not found')
    replace_wscript.write_text(replace_wscript_text.replace(dl_source_old, dl_source_new, 1), encoding='utf-8')

# Android arm64 heap pointers carry a top-byte tag. Compare numeric address
# bits only, keeping the original pointer (and its tag) intact for access/free.
# Check before addition/multiplication, including crossing the TBI address bound.
overflow_header = Path(sys.argv[1]) / 'lib' / 'util' / 'overflow.h'
overflow_text = overflow_header.read_text(encoding='utf-8')
overflow_old = '#define ptr_overflow(ptr, offset, type) \\\n\toffset_outside_range((ptr), ((type*)INTPTR_MAX), (offset))'
overflow_new = '''#if defined(__ANDROID__) && defined(__aarch64__)
#define ptr_overflow(ptr, offset, type) \\
    ((uintptr_t)(offset) > (((UINTPTR_MAX >> 8) - \\
        ((uintptr_t)(ptr) & (UINTPTR_MAX >> 8))) / sizeof(type)))
#else
''' + overflow_old + '\n#endif'
if overflow_new not in overflow_text:
    if overflow_old not in overflow_text:
        raise SystemExit('Expected Samba pointer overflow macro was not found')
    overflow_header.write_text(overflow_text.replace(overflow_old, overflow_new, 1), encoding='utf-8')
