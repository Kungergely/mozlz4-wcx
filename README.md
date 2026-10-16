mozlz4-wcx - Total Commander mozlz4 compression plug-in
================================

mozlz4-wcx is a Total Commander plug-in meant to extract, view, compress and create files in the mozlz4 format used by 
the Mozilla Firefox browser. It's a single-file format (with an extra header compared to vanilla lz4 files) so the
plug-in only allows a single file to be compressed.

The plug-in is completely written in Cython and can be used as a **reference implementation of Cython Total Commander plug-ins in the future.**

By default it's configured for .mozlz4, .baklz4 and .jsonlz4 extensions

**Only 64-bit version is supported at this time.**

Installation
-------------------------

Just double-click on the downloaded ZIP file (or select it and press ENTER), Total Commander will automatically offer you
to install the plug-in.


Building mozlz4-wcx - Using Visual Studio 2022 or later
-------------------------

- Obtain and build lz4 (run build-and-test-x64-release.bat from its build\VS2022 folder)
- Install the Python dependencies (Cython and setuptools) by running `python -m pip install .` in the workdir
- Set the appropriate environmental variables to point to the library built in the previous step and its header files:
```
set LZ4_INCLUDE=C:\path\to\lz4-1.10.0\lib
set LZ4_LIBDIR=C:\path\to\lz4-1.10.0\build\VS2022\bin\x64_Release
set LZ4_LINK=dynamic
```
- Build the plug-in by running `python setup.py build_ext`
- Compress all the resulting files in the dist folder into a zip file

License
-------------------------

mozlz4-wcx is licensed under the MIT License. Copyright (c) 2026 Gergely Kún.

The plug-in bundles third-party libraries listed below:

The lz4 library is licensed under a BSD 2-Clause license, Copyright (c) 2011-2020, Yann Collet.

The Python library is licensed under PSF license version 2, Copyright (c) 2001-2024 Python Software Foundation.

The Microsoft C runtime libraries is licensed under the Microsoft Visual Studio Software License Terms, Copyright (c) Microsoft Corporation.