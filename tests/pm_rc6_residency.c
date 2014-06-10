/*
 * Copyright © 2012 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 *
 * Authors:
 *    Ben Widawsky <ben@bwidawsk.net>
 *
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include "drmtest.h"

#define SLEEP_DURATION 3000 // in milliseconds
#define RC6_FUDGE 900 // in milliseconds

static unsigned int readit(const char *path)
{
	unsigned int ret;
	int scanned;

	FILE *file;
	file = fopen(path, "r");
	igt_assert_f(file,
		     "Couldn't open %s (%d)\n", path, errno);
	scanned = fscanf(file, "%u", &ret);
	igt_assert(scanned == 1);

	fclose(file);

	return ret;
}

igt_simple_main
{
	const int device = drm_get_card();
	char *path, *pathp, *pathpp;
	int fd, ret;
	unsigned int value1, value1p, value1pp, value2, value2p, value2pp;
	FILE *file;
	int diff;

	igt_skip_on_simulation();

	/* Use drm_open_any to verify device existence */
	fd = drm_open_any();
	close(fd);

	ret = asprintf(&path, "/sys/class/drm/card%d/power/rc6_enable", device);
	igt_assert(ret != -1);

	/* For some reason my ivb isn't idle even after syncing up with the gpu.
	 * Let's add a sleept just to make it happy. */
	sleep(5);

	file = fopen(path, "r");
	igt_require(file);

	/* claim success if no rc6 enabled. */
	if (readit(path) == 0)
		igt_success();

	ret = asprintf(&path, "/sys/class/drm/card%d/power/rc6_residency_ms", device);
	igt_assert(ret != -1);
	ret = asprintf(&pathp, "/sys/class/drm/card%d/power/rc6p_residency_ms", device);
	igt_assert(ret != -1);
	ret = asprintf(&pathpp, "/sys/class/drm/card%d/power/rc6pp_residency_ms", device);
	igt_assert(ret != -1);

	value1 = readit(path);
	value1p = readit(pathp);
	value1pp = readit(pathpp);
	sleep(SLEEP_DURATION / 1000);
	value2 = readit(path);
	value2p = readit(pathp);
	value2pp = readit(pathpp);

	free(pathpp);
	free(pathp);
	free(path);

	diff = (value2pp - value1pp) +
		(value2p - value1p) +
		(value2 - value1);

	igt_assert_f(diff <= (SLEEP_DURATION + RC6_FUDGE),
		     "Diff was too high. That is unpossible\n");
	igt_assert_f(diff >= (SLEEP_DURATION - RC6_FUDGE),
		     "GPU was not in RC6 long enough. Check that "
		     "the GPU is as idle as possible (ie. no X, "
		     "running and running no other tests)\n");
}
