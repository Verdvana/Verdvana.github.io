#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <dlfcn.h>
#include <string.h>

static int is_root = 0;
static int d_ino = -1;

static DIR *(*orig_opendir)(const char *name);
static int (*orig_closedir)(DIR *dirp);
static struct dirent *(*orig_readdir)(DIR *dirp);

DIR *opendir(const char *name)
{
	if (strcmp(name, "/") == 0)
		is_root = 1;
	return orig_opendir(name);
}

int closedir(DIR *dirp)
{
	is_root = 0;
	return orig_closedir(dirp);
}

struct dirent *readdir(DIR *dirp)
{
	struct dirent *r = orig_readdir(dirp);
	if (is_root && r)
	{
		if (strcmp(r->d_name, ".") == 0)
			r->d_ino = d_ino;
		else if (strcmp(r->d_name, "..") == 0)
			r->d_ino = d_ino;
	}
	return r;
}

static __attribute__((constructor)) void init_methods()
{
	orig_opendir = dlsym(RTLD_NEXT, "opendir");
	orig_closedir = dlsym(RTLD_NEXT, "closedir");
	orig_readdir = dlsym(RTLD_NEXT, "readdir");
	DIR *d = orig_opendir("/");
	struct dirent *e = orig_readdir(d);
	while (e)
	{
		if (strcmp(e->d_name, ".") == 0)
		{
			d_ino = e->d_ino;
			break;
		}
		e = orig_readdir(d);
	}
	orig_closedir(d);
	if (d_ino == -1)
	{
		puts("Failed to determine root directory inode number");
		exit(EXIT_FAILURE);
	}
}