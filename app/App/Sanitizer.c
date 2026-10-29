#if __has_feature(address_sanitizer)
const char *__asan_default_options(void) {
    return "use_sigaltstack=0";
}
#endif
