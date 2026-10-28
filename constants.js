export const TPATM = 0x400;
export const TPALM = 0x800;
export const PLAYER_BODY_SIZE_INIT = 2;
export const HI_SCORE_LEN = 3;
export const SCORE_PER_APPLE = 10;
export const PLAYER_SPEED = 2;

export const FONT = (x) => 7 + fontTable[x];
export const STRING = (s) => s.split('').map(FONT);

const fontTable = {
    "A": 0,
    "B": 1,
    "C": 2,
    "D": 3,
    "E": 4,
    "F": 5,
    "G": 6,
    "H": 7,
    "I": 8,
    "J": 9,
    "K": 10,
    "L": 11,
    "M": 12,
    "N": 13,
    "O": 14,
    "P": 15,
    "Q": 16,
    "R": 17,
    "S": 18,
    "T": 19,
    "U": 20,
    "V": 21,
    "W": 22,
    "X": 23,
    "Y": 24,
    "Z": 25,
    " ": 71,
    ":": 57,
};
