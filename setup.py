"""
Build the mozlz4 Total Commander plug-in  ->  dist/mozlz4.wcx64

Requirements (build time only): MSVC (VS Build Tools, x64), Python 3.9+ (x64),
    pip install "cython>=3.0" setuptools

Configuration through environment variables
-------------------------------------------
LZ4_ROOT     root of an lz4 install (headers + libs). Layouts understood:
               vcpkg   : <root>/include, <root>/lib/lz4.lib          (x64-windows-static / x64-windows)
               release : <root>/include, <root>/static/liblz4_static.lib, <root>/dll/liblz4.lib
             or set LZ4_INCLUDE / LZ4_LIBDIR explicitly.
LZ4_LINK     static (default) | dynamic
               static  -> lz4 code is inside the .wcx64, no extra DLL.
               dynamic -> needs liblz4.dll next to TC's executable (or on PATH).
LZ4_LIBNAME  override import/static library base name
               (default: static -> "lz4"  [vcpkg]  or "liblz4_static" [release zip, auto-detected];
                         dynamic -> "liblz4")
CRT          static (default, /MT: no vcruntime140.dll dependency) | dynamic (/MD)
BUNDLE_PYTHON 1 (default) | 0
               The plug-in imports pythonXY.dll normally (delay-loading is impossible:
               Cython's module code references data symbols such as Py_NoneStruct, LNK1194).
               1 -> copy pythonXY.dll + vcruntime140(_1).dll from the building interpreter
                    into dist/ so they can ship with the plug-in.
               0 -> copy nothing (Python must then be installed / on PATH on the target PC).
"""
import os
import shutil
import sys
from pathlib import Path

from Cython.Build import cythonize
from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

HERE = Path(__file__).parent.resolve()
IS_WIN = sys.platform == "win32"

lz4_root = os.environ.get("LZ4_ROOT", "")
lz4_link = os.environ.get("LZ4_LINK", "static").lower()
crt = os.environ.get("CRT", "static").lower()
bundle_py = os.environ.get("BUNDLE_PYTHON", "1") == "1"
assert lz4_link in ("static", "dynamic"), "LZ4_LINK must be static|dynamic"
assert crt in ("static", "dynamic"), "CRT must be static|dynamic"


def _first_existing(*paths):
    for p in paths:
        if p and Path(p).exists():
            return str(Path(p))
    return None


include_dir = os.environ.get("LZ4_INCLUDE") or _first_existing(
    lz4_root and Path(lz4_root) / "include")
if lz4_link == "static":
    libdir = os.environ.get("LZ4_LIBDIR") or _first_existing(
        lz4_root and Path(lz4_root) / "static", lz4_root and Path(lz4_root) / "lib")
else:
    libdir = os.environ.get("LZ4_LIBDIR") or _first_existing(
        lz4_root and Path(lz4_root) / "dll", lz4_root and Path(lz4_root) / "lib")

if not include_dir or not (Path(include_dir) / "lz4hc.h").exists():
    sys.exit("lz4.h/lz4hc.h not found: set LZ4_ROOT or LZ4_INCLUDE")
if not libdir:
    sys.exit("lz4 library directory not found: set LZ4_ROOT or LZ4_LIBDIR")

libname = os.environ.get("LZ4_LIBNAME")
if not libname:
    if lz4_link == "dynamic":
        libname = "liblz4"
    else:
        libname = "liblz4_static" if (Path(libdir) / "liblz4_static.lib").exists() else "lz4"

define_macros = []
compile_args, link_args, libraries = [], [], [libname]

if lz4_link == "dynamic":
    define_macros.append(("LZ4_DLL_IMPORT", "1"))   # __declspec(dllimport) for lz4 symbols

if IS_WIN:
    compile_args += ["/O2", "/GL-", "/Gy", "/MT" if crt == "static" else "/MD"]
    link_args += ["/OPT:REF", "/OPT:ICF"]

# Cython's `cdef public` does NOT mark functions dllexport here, and setuptools only
# exports PyInit_mozlz4 by default -> list every WCX entry point explicitly.
WCX_EXPORTS = [
    "OpenArchiveW", "ReadHeaderExW", "ProcessFileW", "CloseArchive",
    "SetChangeVolProcW", "SetProcessDataProcW", "GetPackerCaps",
    "CanYouHandleThisFileW", "PackFilesW",
    "OpenArchive", "ReadHeader", "ProcessFile",
    "SetChangeVolProc", "SetProcessDataProc",
]

ext = Extension(
    "mozlz4",
    sources=["mozlz4.pyx"],
    include_dirs=[include_dir],
    library_dirs=[libdir],
    libraries=libraries,
    define_macros=define_macros,
    extra_compile_args=compile_args,
    extra_link_args=link_args,
    export_symbols=WCX_EXPORTS,   # setuptools appends PyInit_mozlz4 itself
)


class BuildWcx(build_ext):
    """Builds the extension (a DLL) and copies it to dist/mozlz4.wcx64."""

    def run(self):
        super().run()
        out = HERE / "dist"
        out.mkdir(exist_ok=True)
        for e in self.extensions:
            shutil.copy2(self.get_ext_fullpath(e.name), out / "mozlz4.wcx64")
        if lz4_link == "dynamic":
            for dll in Path(libdir).parent.rglob("liblz4.dll"):
                shutil.copy2(dll, out / "liblz4.dll")
                break
        if bundle_py and IS_WIN:
            base = Path(sys.base_prefix)
            pydll = f"python{sys.version_info.major}{sys.version_info.minor}.dll"
            for name in (pydll, "vcruntime140.dll", "vcruntime140_1.dll"):
                src = base / name
                if src.exists():
                    shutil.copy2(src, out / name)
                else:
                    print(f"warning: {src} not found, not bundled")
        shutil.copy2(HERE / "pluginst.inf", out / "pluginst.inf")
        print(f"\n==> {out / 'mozlz4.wcx64'}")


setup(
    name="mozlz4-wcx",
    version="1.0",
    ext_modules=cythonize([ext], language_level=3),
    cmdclass={"build_ext": BuildWcx},
)
