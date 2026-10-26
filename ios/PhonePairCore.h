#pragma once
#include <stdint.h>
int32_t pp_start(const char *directory);
int32_t pp_verify(const char *directory);
void pp_stop(void);
char *pp_snapshot(void);
void pp_free(char *value);
