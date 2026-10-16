/// QBE driver shim, exposes a simple compile API over QBE's internals.
/// Includes only what's needed: globals (T, debug), parse callbacks, and
/// the full main.c func()/data() pipeline behind qbe_compile().
///
/// Build: linked into libqbe_zig alongside all QBE .c files EXCEPT main.c.
#include "all.h"

#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

Target T;
char debug['Z' + 1] = {0};

// Error handling via setjmp/longjmp instead of exit/abort.
// We wrap parse.c's err() by defining it here (so it's used instead of
// parse.c's). die_() from util.c is also overridden.
static jmp_buf qbe_err_jmp;
static FILE *outf;

// Target table (from main.c, but we don't need config.h)
extern Target T_amd64_sysv;
extern Target T_amd64_apple;
extern Target T_amd64_win;
extern Target T_arm64;
extern Target T_arm64_apple;
extern Target T_rv64;

static Target *tlist[] = {
    &T_amd64_sysv,
    &T_amd64_apple,
    &T_amd64_win,
    &T_arm64,
    &T_arm64_apple,
    &T_rv64,
    0,
};

// Pipeline copied from main.c's func()
static void emit_data(Dat *d) {
    emitdat(d, outf);
    if (d->type == DEnd) {
        fputs("/* end data */\n\n", outf);
        freeall();
    }
}

static void emit_dbgfile(char *fn) {
    emitdbgfile(fn, outf);
}

static void compile_fn(Fn *fn) {
    uint n;

    if (debug['P']) {
        fprintf(stderr, "\n> After parsing:\n");
        printfn(fn, stderr);
    }
    T.abi0(fn);
    fillcfg(fn);
    filluse(fn);
    promote(fn);
    filluse(fn);
    ssa(fn);
    filluse(fn);
    ssacheck(fn);
    fillalias(fn);
    loadopt(fn);
    filluse(fn);
    fillalias(fn);
    coalesce(fn);
    filluse(fn);
    filldom(fn);
    ssacheck(fn);
    gvn(fn);
    fillcfg(fn);
    simplcfg(fn);
    filluse(fn);
    filldom(fn);
    gcm(fn);
    filluse(fn);
    ssacheck(fn);
    if (T.cansel) {
        ifconvert(fn);
        fillcfg(fn);
        filluse(fn);
        filldom(fn);
        ssacheck(fn);
    }
    T.abi1(fn);
    simpl(fn);
    fillcfg(fn);
    filluse(fn);
    T.isel(fn);
    fillcfg(fn);
    filllive(fn);
    fillloop(fn);
    fillcost(fn);
    spill(fn);
    rega(fn);
    fillcfg(fn);
    simpljmp(fn);
    fillcfg(fn);
    assert(fn->rpo[0] == fn->start);
    for (n = 0;; n++) {
        if (n == fn->nblk - 1) {
            fn->rpo[n]->link = 0;
            break;
        }
        fn->rpo[n]->link = fn->rpo[n + 1];
    }
    T.emitfn(fn, outf);
    fprintf(outf, "/* end function %s */\n\n", fn->name);
    freeall();
}

// Public API
int qbe_set_target(const char *name) {
    if (strcmp(name, "?") == 0) {
        puts(T.name);
        return 0;
    }
    for (Target **t = tlist; *t != NULL; t++) {
        if (strcmp(name, (*t)->name) == 0) {
            T = **t;
            return 0;
        }
    }
    return -1;
}

// Compile SSA from memory buffer, write asm to memory buffer.
// Returns 0 on success, -1 on error. Output must be freed by caller.
int qbe_compile(const char *ssa_text, size_t ssa_len, char **out_asm, size_t *out_len) {
    FILE *inf = fmemopen((void *)ssa_text, ssa_len, "r");
    if (inf == NULL) {
        return -1;
    }

    outf = open_memstream(out_asm, out_len);
    if (outf == NULL) {
        fclose(inf);
        return -1;
    }

    int rc = 0;
    if (setjmp(qbe_err_jmp) == 0) {
        parse(inf, "<string>", emit_dbgfile, emit_data, compile_fn);
        if (!debug['Z']) {
            T.emitfin(outf);
        }
    } else {
        rc = -1;
    }

    fclose(inf);
    fclose(outf);
    return rc;
}
