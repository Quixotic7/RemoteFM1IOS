// SPDX-License-Identifier: GPL-3.0-only
// rfmbench [WASM_DIR] [SPEC words..]: the bench on the Mac (bench.h). Prints the report as it goes.
#include <cstdio>
#include <cstdlib>
#include <string>

#include "bench.h"

static void line(const char *s)
{
    std::printf("%s\n", s);
    std::fflush(stdout);
}

int main(int argc, char **argv)
{
    std::string dir = ".", spec;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a.find('=') == std::string::npos)
            dir = a;
        else
            spec += (spec.empty() ? "" : " ") + a;
    }
    char *r = rfmbench_run(dir.c_str(), spec.empty() ? nullptr : spec.c_str(), line);
    std::free(r);
    return 0;
}
