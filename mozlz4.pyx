# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
#
# Total Commander WCX (packer) plug-in for Mozilla "mozlz4" containers
# (.mozlz4, .jsonlz4, .baklz4 -- bookmarks backups, session store, search.json, ...)
#
# Format:  "mozLz40\0" (8 bytes) | uint32 LE decompressed size | raw LZ4 block
#
# IMPORTANT DESIGN RULE
# ---------------------
# Total Commander loads this file as a plain Windows DLL. The Python interpreter is
# NEVER initialised. Every exported function is therefore `noexcept nogil` and uses
# C types only -- the Cython compiler enforces this (it refuses Python-object use
# inside nogil code). Do not add Python objects, `print`, `raise`, closures, etc.
#
# 64-bit only (TC64 loads *.wcx64). On x64 there is a single calling convention,
# so no __stdcall decoration is needed.

from libc.stddef cimport wchar_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcmp, memcpy, memset
from libc.stdio cimport FILE, fclose, fread, fwrite, SEEK_SET, SEEK_END
from libc.time cimport tm

# ---------------------------------------------------------------- C externs
cdef extern from "lz4.h" nogil:
    int LZ4_compressBound(int inputSize)
    int LZ4_decompress_safe(const char* src, char* dst, int compressedSize, int dstCapacity)

cdef extern from "lz4hc.h" nogil:
    int LZ4_compress_HC(const char* src, char* dst, int srcSize, int dstCapacity, int compressionLevel)

cdef extern from "<wchar.h>" nogil:
    size_t wcslen(const wchar_t* s)
    FILE* _wfopen(const wchar_t* filename, const wchar_t* mode)
    int _wremove(const wchar_t* path)

cdef extern from "<stdio.h>" nogil:
    int _fseeki64(FILE* f, long long offset, int origin)
    long long _ftelli64(FILE* f)

cdef extern from "<sys/stat.h>" nogil:
    ctypedef struct stat64_t "struct _stat64":
        unsigned short st_mode
        long long st_size
        long long st_mtime
    int _wstat64(const wchar_t* path, stat64_t* buf)

cdef extern from "<time.h>" nogil:
    int _localtime64_s(tm* out, const long long* t)

# ---------------------------------------------------------------- WCX constants
cdef enum:
    E_END_ARCHIVE = 10
    E_NO_MEMORY = 11
    E_BAD_DATA = 12
    E_BAD_ARCHIVE = 13
    E_ECREATE = 16
    E_ECLOSE = 17
    E_EREAD = 18
    E_EWRITE = 19
    E_EABORTED = 21
    E_NO_FILES = 22
    E_TOO_MANY_FILES = 23
    E_NOT_SUPPORTED = 24
    E_EOPEN = 15

    PK_SKIP = 0
    PK_TEST = 1
    PK_EXTRACT = 2

    PK_PACK_MOVE_FILES = 1

    PK_CAPS_NEW = 1
    PK_CAPS_BY_CONTENT = 32

    HDR_NAME_LEN = 1024
    PATH_BUF = 2048
    HC_LEVEL = 9

ctypedef int (*ProcessDataProcW)(wchar_t* FileName, int Size) noexcept nogil

# ---------------------------------------------------------------- WCX structs
cdef struct OpenArchiveDataW:
    wchar_t* ArcName
    int OpenMode
    int OpenResult
    wchar_t* CmtBuf
    int CmtBufSize
    int CmtSize
    int CmtState

cdef struct OpenArchiveDataA:
    char* ArcName
    int OpenMode
    int OpenResult
    char* CmtBuf
    int CmtBufSize
    int CmtSize
    int CmtState

cdef struct HeaderDataExW:
    wchar_t ArcName[1024]
    wchar_t FileName[1024]
    int Flags
    unsigned int PackSize
    unsigned int PackSizeHigh
    unsigned int UnpSize
    unsigned int UnpSizeHigh
    int HostOS
    int FileCRC
    int FileTime
    int UnpVer
    int Method
    int FileAttr
    char* CmtBuf
    int CmtBufSize
    int CmtSize
    int CmtState
    char Reserved[1024]

cdef struct ArcState:
    wchar_t arc[1024]
    wchar_t inner[1024]
    unsigned int unp
    unsigned int pack
    int ftime
    int attr
    int served
    ProcessDataProcW pdp

# ---------------------------------------------------------------- helpers
cdef inline unsigned int get_u32le(const unsigned char* p) noexcept nogil:
    return (<unsigned int>p[0]) | ((<unsigned int>p[1]) << 8) | ((<unsigned int>p[2]) << 16) | ((<unsigned int>p[3]) << 24)

cdef inline void put_u32le(unsigned char* p, unsigned int v) noexcept nogil:
    p[0] = v & 0xFF
    p[1] = (v >> 8) & 0xFF
    p[2] = (v >> 16) & 0xFF
    p[3] = (v >> 24) & 0xFF

cdef int wcopy(wchar_t* dst, int cap, const wchar_t* src) noexcept nogil:
    """Bounded copy. 0 = ok, -1 = truncated."""
    cdef int i = 0
    if cap <= 0:
        return -1
    while src[i] != 0:
        if i >= cap - 1:
            dst[i] = 0
            return -1
        dst[i] = src[i]
        i += 1
    dst[i] = 0
    return 0

cdef int wcat(wchar_t* dst, int cap, const wchar_t* src) noexcept nogil:
    cdef int n = <int>wcslen(dst)
    return wcopy(dst + n, cap - n, src)

cdef void put_ascii(wchar_t* dst, int cap, const char* s) noexcept nogil:
    cdef int n = <int>wcslen(dst)
    cdef int i = 0
    while s[i] != 0 and n < cap - 1:
        dst[n] = s[i]
        n += 1
        i += 1
    dst[n] = 0

cdef bint ext_is(const wchar_t* e, const char* a) noexcept nogil:
    cdef int i = 0
    cdef int c
    while a[i] != 0:
        c = e[i]
        if c >= 65 and c <= 90:
            c += 32
        if c != a[i]:
            return False
        i += 1
    return e[i] == 0

cdef void make_inner(const wchar_t* arc, wchar_t* out, int cap) noexcept nogil:
    """foo.jsonlz4 -> foo.json | recovery.baklz4 -> recovery.json | search.json.mozlz4 -> search.json"""
    cdef int i = 0
    cdef int base = 0
    cdef int n = 0
    cdef int dot = -1
    while arc[i] != 0:
        if arc[i] == 92 or arc[i] == 47:
            base = i + 1
        i += 1
    i = base
    while arc[i] != 0 and n < cap - 16:
        if arc[i] == 46:
            dot = n
        out[n] = arc[i]
        n += 1
        i += 1
    out[n] = 0
    if dot > 0:
        if ext_is(out + dot + 1, b"jsonlz4") or ext_is(out + dot + 1, b"baklz4"):
            out[dot] = 0
            put_ascii(out, cap, b".json")
        else:
            out[dot] = 0
    else:
        put_ascii(out, cap, b".unpacked")

cdef int read_file(const wchar_t* path, unsigned char** out, size_t* nread,
                   long long* total, size_t limit) noexcept nogil:
    """Reads the file (or its first `limit` bytes if limit>0). Caller frees *out."""
    cdef wchar_t m[3]
    cdef FILE* f
    cdef long long sz
    cdef size_t want
    cdef unsigned char* buf
    m[0] = 114  # r
    m[1] = 98   # b
    m[2] = 0
    f = _wfopen(path, m)
    if f == NULL:
        return E_EOPEN
    if _fseeki64(f, 0, SEEK_END) != 0:
        fclose(f)
        return E_EREAD
    sz = _ftelli64(f)
    if _fseeki64(f, 0, SEEK_SET) != 0 or sz < 0:
        fclose(f)
        return E_EREAD
    if sz > 0x7FFFFFFF:
        fclose(f)
        return E_NO_MEMORY
    want = <size_t>sz
    if limit > 0 and want > limit:
        want = limit
    buf = <unsigned char*>malloc(want if want > 0 else 1)
    if buf == NULL:
        fclose(f)
        return E_NO_MEMORY
    if want > 0 and fread(buf, 1, want, f) != want:
        free(buf)
        fclose(f)
        return E_EREAD
    fclose(f)
    out[0] = buf
    nread[0] = want
    total[0] = sz
    return 0

cdef int write_file(const wchar_t* path, const unsigned char* buf, size_t n) noexcept nogil:
    cdef wchar_t m[3]
    cdef FILE* f
    m[0] = 119  # w
    m[1] = 98   # b
    m[2] = 0
    f = _wfopen(path, m)
    if f == NULL:
        return E_ECREATE
    if n > 0 and fwrite(buf, 1, n, f) != n:
        fclose(f)
        _wremove(path)
        return E_EWRITE
    if fclose(f) != 0:
        _wremove(path)
        return E_ECLOSE
    return 0

cdef int parse_header(const unsigned char* b, size_t n, unsigned int* usize) noexcept nogil:
    if n < 12 or memcmp(b, b"mozLz40\x00", 8) != 0:
        return E_BAD_ARCHIVE
    usize[0] = get_u32le(b + 8)
    return 0

cdef int unpack_all(const wchar_t* path, unsigned char** out, unsigned int* usize) noexcept nogil:
    cdef unsigned char* buf = NULL
    cdef unsigned char* dst
    cdef size_t n = 0
    cdef long long total = 0
    cdef size_t alloc
    cdef int r
    cdef int rc = read_file(path, &buf, &n, &total, 0)
    if rc != 0:
        return rc
    rc = parse_header(buf, n, usize)
    if rc != 0:
        free(buf)
        return rc
    # LZ4 cannot expand more than ~255x: reject absurd (malicious) size fields
    if usize[0] > 0x7FFFFFFF or (<unsigned long long>usize[0]) > (<unsigned long long>(n - 12)) * 255 + 255:
        free(buf)
        return E_BAD_DATA
    alloc = usize[0]
    if alloc == 0:
        alloc = 1
    dst = <unsigned char*>malloc(alloc)
    if dst == NULL:
        free(buf)
        return E_NO_MEMORY
    r = LZ4_decompress_safe(<const char*>(buf + 12), <char*>dst, <int>(n - 12), <int>usize[0])
    free(buf)
    if r < 0 or (<unsigned int>r) != usize[0]:
        free(dst)
        return E_BAD_DATA
    out[0] = dst
    return 0

cdef int dos_time(const wchar_t* path) noexcept nogil:
    cdef stat64_t st
    cdef tm t
    cdef long long mt
    if _wstat64(path, &st) != 0:
        return 0
    mt = st.st_mtime
    if _localtime64_s(&t, &mt) != 0:
        return 0
    return (((t.tm_year + 1900 - 1980) << 25) | ((t.tm_mon + 1) << 21) | (t.tm_mday << 16)
            | (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2))

# ---------------------------------------------------------------- WCX exports
cdef public void* OpenArchiveW(void* dp) noexcept nogil:
    cdef OpenArchiveDataW* d = <OpenArchiveDataW*>dp
    cdef ArcState* s
    cdef unsigned char* buf = NULL
    cdef size_t n = 0
    cdef long long total = 0
    cdef unsigned int us = 0
    cdef int rc
    d.OpenResult = 0
    s = <ArcState*>malloc(sizeof(ArcState))
    if s == NULL:
        d.OpenResult = E_NO_MEMORY
        return NULL
    memset(s, 0, sizeof(ArcState))
    if wcopy(s.arc, 1024, d.ArcName) != 0:
        free(s)
        d.OpenResult = E_EOPEN
        return NULL
    rc = read_file(d.ArcName, &buf, &n, &total, 12)
    if rc != 0:
        free(s)
        d.OpenResult = rc
        return NULL
    rc = parse_header(buf, n, &us)
    free(buf)
    if rc != 0:
        free(s)
        d.OpenResult = rc
        return NULL
    s.unp = us
    s.pack = <unsigned int>total
    s.attr = 0x20
    s.ftime = dos_time(d.ArcName)
    make_inner(s.arc, s.inner, 1024)
    return s

cdef public int ReadHeaderExW(void* h, void* hdp) noexcept nogil:
    cdef ArcState* s = <ArcState*>h
    cdef HeaderDataExW* hd = <HeaderDataExW*>hdp
    if s == NULL or s.served:
        return E_END_ARCHIVE
    memset(hd, 0, sizeof(HeaderDataExW))
    wcopy(hd.ArcName, HDR_NAME_LEN, s.arc)
    wcopy(hd.FileName, HDR_NAME_LEN, s.inner)
    hd.PackSize = s.pack
    hd.UnpSize = s.unp
    hd.FileTime = s.ftime
    hd.FileAttr = s.attr
    s.served = 1
    return 0

cdef public int ProcessFileW(void* h, int op, wchar_t* destPath, wchar_t* destName) noexcept nogil:
    cdef ArcState* s = <ArcState*>h
    cdef wchar_t dest[2048]
    cdef unsigned char* data = NULL
    cdef unsigned int us = 0
    cdef int rc
    if s == NULL:
        return E_BAD_DATA
    if op == PK_SKIP:
        return 0
    if op != PK_TEST and op != PK_EXTRACT:
        return E_NOT_SUPPORTED
    rc = unpack_all(s.arc, &data, &us)
    if rc != 0:
        return rc
    if op == PK_EXTRACT:
        dest[0] = 0
        if destPath != NULL:
            if wcat(dest, PATH_BUF, destPath) != 0:
                free(data)
                return E_ECREATE
        if destName != NULL:
            if wcat(dest, PATH_BUF, destName) != 0:
                free(data)
                return E_ECREATE
        rc = write_file(dest, data, us)
        if rc != 0:
            free(data)
            return rc
    free(data)
    if s.pdp != NULL:
        if s.pdp(s.inner, <int>us) == 0:
            return E_EABORTED
    return 0

cdef public int CloseArchive(void* h) noexcept nogil:
    if h != NULL:
        free(h)
    return 0

cdef public void SetChangeVolProcW(void* h, void* p) noexcept nogil:
    pass

cdef public void SetProcessDataProcW(void* h, void* p) noexcept nogil:
    if h != NULL:
        (<ArcState*>h).pdp = <ProcessDataProcW>p

cdef public int GetPackerCaps() noexcept nogil:
    return PK_CAPS_NEW | PK_CAPS_BY_CONTENT

cdef public int CanYouHandleThisFileW(wchar_t* name) noexcept nogil:
    cdef unsigned char* buf = NULL
    cdef size_t n = 0
    cdef long long total = 0
    cdef int ok = 0
    if read_file(name, &buf, &n, &total, 12) == 0:
        if n >= 8 and memcmp(buf, b"mozLz40\x00", 8) == 0:
            ok = 1
        free(buf)
    return ok

cdef public int PackFilesW(wchar_t* packed, wchar_t* sub, wchar_t* src,
                           wchar_t* addlist, int flags) noexcept nogil:
    """Packs exactly ONE file into a new mozlz4 container."""
    cdef wchar_t srcpath[2048]
    cdef stat64_t st
    cdef unsigned char* data = NULL
    cdef unsigned char* out
    cdef size_t n = 0
    cdef long long total = 0
    cdef int rc
    cdef int c
    cdef size_t first_len
    if addlist == NULL or addlist[0] == 0:
        return E_NO_FILES
    first_len = wcslen(addlist)
    if addlist[first_len + 1] != 0:
        return E_TOO_MANY_FILES
    srcpath[0] = 0
    if src != NULL:
        if wcat(srcpath, PATH_BUF, src) != 0:
            return E_EOPEN
    if wcat(srcpath, PATH_BUF, addlist) != 0:
        return E_EOPEN
    if _wstat64(srcpath, &st) == 0 and (st.st_mode & 0x4000) != 0:
        return E_NOT_SUPPORTED          # directories can't be stored
    rc = read_file(srcpath, &data, &n, &total, 0)
    if rc != 0:
        return rc
    out = <unsigned char*>malloc(12 + <size_t>LZ4_compressBound(<int>n))
    if out == NULL:
        free(data)
        return E_NO_MEMORY
    memcpy(out, b"mozLz40\x00", 8)
    put_u32le(out + 8, <unsigned int>n)
    c = LZ4_compress_HC(<const char*>data, <char*>(out + 12), <int>n,
                        LZ4_compressBound(<int>n), HC_LEVEL)
    free(data)
    if c <= 0:
        free(out)
        return E_BAD_DATA
    rc = write_file(packed, out, 12 + <size_t>c)
    free(out)
    if rc != 0:
        return rc
    if (flags & PK_PACK_MOVE_FILES) != 0:
        _wremove(srcpath)
    return 0

# ---- ANSI entry points: TC requires them to exist; Unicode (…W) variants are used by TC >= 5.5
cdef public void* OpenArchive(void* dp) noexcept nogil:
    cdef OpenArchiveDataA* d = <OpenArchiveDataA*>dp
    d.OpenResult = E_NOT_SUPPORTED
    return NULL

cdef public int ReadHeader(void* h, void* hd) noexcept nogil:
    return E_END_ARCHIVE

cdef public int ProcessFile(void* h, int op, char* destPath, char* destName) noexcept nogil:
    return E_NOT_SUPPORTED

cdef public void SetChangeVolProc(void* h, void* p) noexcept nogil:
    pass

cdef public void SetProcessDataProc(void* h, void* p) noexcept nogil:
    pass
