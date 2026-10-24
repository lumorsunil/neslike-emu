export const asm = (strings, ...values) => strings.map(
    (s, i) => `${s}${values[i] || ""}`
).join('');
