_Thread_local int tlv_counter = 42;

int tlv_value(void) {
    tlv_counter += 1;
    return tlv_counter;
}
