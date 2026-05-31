static int value = 0;

__attribute__((constructor)) static void initialize(void) { value = 42; }

int ctor_answer(void) { return value; }
