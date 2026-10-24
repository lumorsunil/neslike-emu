;  Note   Octave  0   Octave  1   Octave  2   Octave  3   Octave  4   Octave  5   Octave   6   Octave   7   Octave   8
;  C      16.35   Hz  32.70   Hz  65.41   Hz  130.81  Hz  261.63  Hz  523.25  Hz  1046.50  Hz  2093.00  Hz  4186.01  Hz
;  C#/Db  17.32   Hz  34.65   Hz  69.30   Hz  138.59  Hz  277.18  Hz  554.37  Hz  1108.73  Hz  2217.46  Hz  4434.92  Hz
;  D      18.35   Hz  36.71   Hz  73.42   Hz  146.83  Hz  293.66  Hz  587.33  Hz  1174.66  Hz  2349.32  Hz  4698.63  Hz
;  D#/Eb  19.45   Hz  38.89   Hz  77.78   Hz  155.56  Hz  311.13  Hz  622.25  Hz  1244.51  Hz  2489.02  Hz  4978.03  Hz
;  E      20.60   Hz  41.20   Hz  82.41   Hz  164.81  Hz  329.63  Hz  659.25  Hz  1318.51  Hz  2637.02  Hz  5274.04  Hz
;  F      21.83   Hz  43.65   Hz  87.31   Hz  174.61  Hz  349.23  Hz  698.46  Hz  1396.91  Hz  2793.83  Hz  5587.65  Hz
;  F#/Gb  23.12   Hz  46.25   Hz  92.50   Hz  185     Hz  369.99  Hz  739.99  Hz  1479.98  Hz  2959.96  Hz  5919.91  Hz
;  G      24.50   Hz  49      Hz  98      Hz  196     Hz  392     Hz  783.99  Hz  1567.98  Hz  3135.96  Hz  6271.93  Hz
;  G#/Ab  25.96   Hz  51.91   Hz  103.83  Hz  207.65  Hz  415.30  Hz  830.61  Hz  1661.22  Hz  3322.44  Hz  6644.88  Hz
;  A      27.50   Hz  55      Hz  110     Hz  220     Hz  440     Hz  880     Hz  1760     Hz  3520     Hz  7040     Hz
;  A#/Bb  29.14   Hz  58.27   Hz  116.54  Hz  233.08  Hz  466.16  Hz  932.33  Hz  1864.66  Hz  3729.31  Hz  7458.62  Hz
;  B      30.87   Hz  61.74   Hz  123.47  Hz  246.94  Hz  493.88  Hz  987.77  Hz  1975.53  Hz  3951.07  Hz  7902.13  Hz

    MAC N_0
        byte 0, 0, 0
    ENDM
N_0_0 EQU 0
N_0_1 EQU 0
N_0_2 EQU 0
    MAC C_0 
        word $0010
        byte 35
    ENDM
    MAC C_1 
        word $0020
        byte 70
    ENDM
    MAC C_2 
        word $0041
        byte 41
    ENDM
    MAC C_3 
        word $0082
        byte 81
    ENDM
C_3_0 EQU $82
C_3_1 EQU $00
C_3_2 EQU 81
    MAC C_4 
        word $0105
        byte 63
    ENDM
    MAC C_5 
        word $020b
        byte 25
    ENDM
    MAC C_6 
        word $0416
        byte 50
    ENDM
    MAC C_7 
        word $082d
        byte 00
    ENDM
    MAC C_8 
        word $105a
        byte 01
    ENDM
    MAC CS_0 
        word $0011
        byte 32
    ENDM
    MAC Db_0 
        word $0011
        byte 32
    ENDM
    MAC CS_1 
        word $0022
        byte 65
    ENDM
    MAC Db_1 
        word $0022
        byte 65
    ENDM
    MAC CS_2 
        word $0045
        byte 30
    ENDM
    MAC Db_2 
        word $0045
        byte 30
    ENDM
    MAC CS_3 
        word $008a
        byte 59
    ENDM
    MAC Db_3 
        word $008a
        byte 59
    ENDM
    MAC CS_4 
        word $0115
        byte 18
    ENDM
    MAC Db_4 
        word $0115
        byte 18
    ENDM
    MAC CS_5 
        word $022a
        byte 37
    ENDM
    MAC Db_5 
        word $022a
        byte 37
    ENDM
    MAC CS_6 
        word $0454
        byte 73
    ENDM
    MAC Db_6 
        word $0454
        byte 73
    ENDM
    MAC CS_7 
        word $08a9
        byte 46
    ENDM
    MAC Db_7 
        word $08a9
        byte 46
    ENDM
    MAC CS_8 
        word $1152
        byte 92
    ENDM
    MAC Db_8 
        word $1152
        byte 92
    ENDM
    MAC D_0 
        word $0012
        byte 35
    ENDM
    MAC D_1 
        word $0024
        byte 71
    ENDM
    MAC D_2 
        word $0049
        byte 42
    ENDM
    MAC D_3 
        word $0092
        byte 83
    ENDM
    MAC D_4 
        word $0125
        byte 66
    ENDM
    MAC D_5 
        word $024b
        byte 33
    ENDM
    MAC D_6 
        word $0496
        byte 66
    ENDM
    MAC D_7 
        word $092d
        byte 32
    ENDM
    MAC D_8 
        word $125a
        byte 63
    ENDM
    MAC DS_0 
        word $0013
        byte 45
    ENDM
    MAC Eb_0 
        word $0013
        byte 45
    ENDM
    MAC DS_1 
        word $0026
        byte 89
    ENDM
    MAC Eb_1 
        word $0026
        byte 89
    ENDM
    MAC DS_2 
        word $004d
        byte 78
    ENDM
    MAC Eb_2 
        word $004d
        byte 78
    ENDM
    MAC DS_3 
        word $009b
        byte 56
    ENDM
    MAC Eb_3 
        word $009b
        byte 56
    ENDM
    MAC DS_4 
        word $0137
        byte 13
    ENDM
    MAC Eb_4 
        word $0137
        byte 13
    ENDM
    MAC DS_5 
        word $026e
        byte 25
    ENDM
    MAC Eb_5 
        word $026e
        byte 25
    ENDM
    MAC DS_6 
        word $04dc
        byte 51
    ENDM
    MAC Eb_6 
        word $04dc
        byte 51
    ENDM
    MAC DS_7 
        word $09b9
        byte 02
    ENDM
    MAC Eb_7 
        word $09b9
        byte 02
    ENDM
    MAC DS_8 
        word $1372
        byte 03
    ENDM
    MAC Eb_8 
        word $1372
        byte 03
    ENDM
    MAC E_0 
        word $0014
        byte 60
    ENDM
    MAC E_1 
        word $0029
        byte 20
    ENDM
    MAC E_2 
        word $0052
        byte 41
    ENDM
    MAC E_3 
        word $00a4
        byte 81
    ENDM
E_3_0 EQU $A4
E_3_1 EQU $00
E_3_2 EQU 81
    MAC E_4 
        word $0149
        byte 63
    ENDM
    MAC E_5 
        word $0293
        byte 25
    ENDM
    MAC E_6 
        word $0526
        byte 51
    ENDM
    MAC E_7 
        word $0a4d
        byte 02
    ENDM
    MAC E_8 
        word $149a
        byte 04
    ENDM
    MAC F_0 
        word $0015
        byte 83
    ENDM
    MAC F_1 
        word $002b
        byte 65
    ENDM
    MAC F_2 
        word $0057
        byte 31
    ENDM
    MAC F_3 
        word $00ae
        byte 61
    ENDM
    MAC F_4 
        word $015d
        byte 23
    ENDM
    MAC F_5 
        word $02ba
        byte 46
    ENDM
    MAC F_6 
        word $0574
        byte 91
    ENDM
    MAC F_7 
        word $0ae9
        byte 83
    ENDM
    MAC F_8 
        word $15d3
        byte 65
    ENDM
    MAC FS_0 
        word $0017
        byte 12
    ENDM
    MAC Gb_0 
        word $0017
        byte 12
    ENDM
    MAC FS_1 
        word $002e
        byte 25
    ENDM
    MAC Gb_1 
        word $002e
        byte 25
    ENDM
    MAC FS_2 
        word $005c
        byte 50
    ENDM
    MAC Gb_2 
        word $005c
        byte 50
    ENDM
    MAC FS_3 
        word $00b9
        byte 00
    ENDM
    MAC Gb_3 
        word $00b9
        byte 00
    ENDM
    MAC FS_4 
        word $0171
        byte 99
    ENDM
    MAC Gb_4 
        word $0171
        byte 99
    ENDM
    MAC FS_5 
        word $02e3
        byte 99
    ENDM
    MAC Gb_5 
        word $02e3
        byte 99
    ENDM
    MAC FS_6 
        word $05c7
        byte 98
    ENDM
    MAC Gb_6 
        word $05c7
        byte 98
    ENDM
    MAC FS_7 
        word $0b8f
        byte 96
    ENDM
    MAC Gb_7 
        word $0b8f
        byte 96
    ENDM
    MAC FS_8 
        word $171f
        byte 91
    ENDM
    MAC Gb_8 
        word $171f
        byte 91
    ENDM
    MAC G_0 
        word $0018
        byte 50
    ENDM
    MAC G_1 
        word $0031
        byte 00
    ENDM
    MAC G_2 
        word $0062
        byte 00
    ENDM
    MAC G_3 
        word $00c4
        byte 00
    ENDM
    MAC G_4 
        word $0188
        byte 00
    ENDM
    MAC G_5 
        word $030f
        byte 99
    ENDM
    MAC G_6 
        word $1567
        byte 98
    ENDM
    MAC G_7 
        word $3135
        byte 96
    ENDM
    MAC G_8 
        word $6271
        byte 93
    ENDM
    MAC GS_0 
        word $25
        byte 96
    ENDM
    MAC Ab_0 
        word $25
        byte 96
    ENDM
    MAC GS_1 
        word $51
        byte 91
    ENDM
    MAC Ab_1 
        word $51
        byte 91
    ENDM
    MAC GS_2 
        word $0067
        byte 83
    ENDM
    MAC Ab_2 
        word $0067
        byte 83
    ENDM
    MAC GS_3 
        word $00cf
        byte 65
    ENDM
    MAC Ab_3 
        word $00cf
        byte 65
    ENDM
    MAC GS_4 
        word $019f
        byte 30
    ENDM
    MAC Ab_4 
        word $019f
        byte 30
    ENDM
    MAC GS_5 
        word $033e
        byte 61
    ENDM
    MAC Ab_5 
        word $033e
        byte 61
    ENDM
    MAC GS_6 
        word $067d
        byte 22
    ENDM
    MAC Ab_6 
        word $067d
        byte 22
    ENDM
    MAC GS_7 
        word $0cfa
        byte 44
    ENDM
    MAC Ab_7 
        word $0cfa
        byte 44
    ENDM
    MAC GS_8 
        word $19f4
        byte 88
    ENDM
    MAC Ab_8 
        word $19f4
        byte 88
    ENDM
    MAC A_0 
        word $001b
        byte 50
    ENDM
    MAC A_1 
        word $0037
        byte 00
    ENDM
    MAC A_2 
        word $006e
        byte 00
    ENDM
    MAC A_3 
        word $00dc
        byte 00
    ENDM
    MAC A_4 
        word $01b8
        byte 00
    ENDM
    MAC A_5 
        word $0370
        byte 00
    ENDM
    MAC A_6 
        word $06e0
        byte 00
    ENDM
    MAC A_7 
        word $0dc0
        byte 00
    ENDM
    MAC A_8 
        word $1b80
        byte 00
    ENDM
    MAC AS_0 
        word $001d
        byte 14
    ENDM
    MAC Bb_0 
        word $001d
        byte 14
    ENDM
    MAC AS_1 
        word $003a
        byte 27
    ENDM
    MAC Bb_1 
        word $003a
        byte 27
    ENDM
    MAC AS_2 
        word $0074
        byte 54
    ENDM
    MAC Bb_2 
        word $0074
        byte 54
    ENDM
    MAC AS_3 
        word $00e9
        byte 08
    ENDM
    MAC Bb_3 
        word $00e9
        byte 08
    ENDM
    MAC AS_4 
        word $01d2
        byte 16
    ENDM
    MAC Bb_4 
        word $01d2
        byte 16
    ENDM
    MAC AS_5 
        word $03a4
        byte 33
    ENDM
    MAC Bb_5 
        word $03a4
        byte 33
    ENDM
    MAC AS_6 
        word $0748
        byte 66
    ENDM
    MAC Bb_6 
        word $0748
        byte 66
    ENDM
    MAC AS_7 
        word $0e91
        byte 31
    ENDM
    MAC Bb_7 
        word $0e91
        byte 31
    ENDM
    MAC AS_8 
        word $1d22
        byte 62
    ENDM
    MAC Bb_8 
        word $1d22
        byte 62
    ENDM
    MAC B_0 
        word $001e
        byte 87
    ENDM
    MAC B_1 
        word $003d
        byte 74
    ENDM
    MAC B_2 
        word $007b
        byte 47
    ENDM
    MAC B_3 
        word $00f6
        byte 94
    ENDM
    MAC B_4 
        word $01ed
        byte 88
    ENDM
    MAC B_5 
        word $03db
        byte 77
    ENDM
    MAC B_6 
        word $07b7
        byte 53
    ENDM
    MAC B_7 
        word $0f6f
        byte 07
    ENDM
    MAC B_8 
        word $1ede
        byte 13
    ENDM
