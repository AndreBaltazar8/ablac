extern long coverage_entry(void);
extern long coverage_entry_two(void);
int main(void) { return (coverage_entry() == 42 && coverage_entry_two() == 42) ? 0 : 1; }
