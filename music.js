import { asm } from "./asm.js";

const instructions = () => asm`
update_music:
    ; dec music_pitch_timer
    ; bne update_music_note
    ; lda #$10
    ; sta music_pitch_timer
    ; dec NOISE_F+1
update_music_note:
update_square_waves:
    dec music_timer_sq
    bne update_triangle_wave
    inc music_state_sq
    lda music_state_sq
    cmp #56
    bne play_music_note_sq
    lda #$00
    sta music_state_sq
play_music_note_sq:
    tax
    lda music_notes_duration_sq,x
    sta music_timer_sq
    lda music_notes_volume_sq,x
    sta SQ1_V
    ; sta SQ2_V
    lda music_notes_SQ1_F0,x
    sta SQ1_F
    lda music_notes_SQ1_F1,x
    sta SQ1_F+1
    lda music_notes_SQ1_F2,x
    sta SQ1_F+2
    lda music_notes_SQ2_F0,x
    sta SQ2_F
    lda music_notes_SQ2_F1,x
    sta SQ2_F+1
    lda music_notes_SQ2_F2,x
    sta SQ2_F+2
update_triangle_wave:
    dec music_timer_tr
    bne update_noise
    inc music_state_tr
    lda music_state_tr
    cmp #16
    bne play_music_note_tr
    lda #$00
    sta music_state_tr
play_music_note_tr:
    tax
    lda music_notes_duration_tr,x
    sta music_timer_tr
    lda music_notes_volume_tr,x
    sta TR_V
    lda music_notes_TR_F0,x
    sta TR_F
    lda music_notes_TR_F1,x
    sta TR_F+1
    lda music_notes_TR_F2,x
    sta TR_F+2
update_noise:
    dec music_timer_ns
    bne end
    inc music_state_ns
    lda music_state_ns
    cmp #12
    bne play_music_note_ns
    lda #$00
    sta music_state_ns
play_music_note_ns:
    tax
    lda music_notes_duration_ns,x
    sta music_timer_ns
    lda music_notes_volume_ns,x
    sta NOISE_V
    lda music_notes_ns_mode,x
    sta NOISE_M
    lda music_notes_NS_F0,x
    sta NOISE_F
    lda music_notes_NS_F1,x
    sta NOISE_F+1
    lda music_notes_NS_F2,x
    sta NOISE_F+2
`;

const generateTables = () => {
    const n = utils.notes;

    const duration_base = 0x10;
    const dur = (d) => duration_base * d;
    const vol = (v) => v;

    const sq1_table_src = [
        n.g4, n.g4, n.d5, n.d5, n.e5, n.e5, n.d5,
        n.c5, n.c5, n.b4, n.b4, n.a4, n.a4, n.g4,
        n.d5, n.d5, n.c5, n.c5, n.b4, n.b4, n.a4,
        n.d5, n.d5, n.c5, n.c5, n.b4, n.b4, n.a4,
    ];
    const sq1_table = sq1_table_src.flatMap(x => [x, n.blank]);

    const sq2_table_src = [
        n.d4, n.d4, n.a4, n.a4, n.b4, n.b4, n.a4,
        n.g4, n.g4, n.fs4, n.fs4, n.e4, n.e4, n.d4,
        n.a4, n.a4, n.g4, n.g4, n.fs4, n.fs4, n.e4,
        n.a4, n.a4, n.g4, n.g4, n.fs4, n.fs4, n.e4,
    ];
    const sq2_table = sq2_table_src.flatMap(x => [x, n.blank]);
    const durations_sq = sq1_table_src.flatMap((x, i) =>
        [(i + 1) % 7 == 0 ? dur(3) : dur(1), dur(1)]
    );
    const volumes_sq = sq1_table_src.flatMap(x => [vol(15), vol(0)]);

    // Protons baseline:
    // g2 g2 c3 g2 c3 g2 d3 g2
    // g2 c3 g2 d3 g2 c3 g2 d3

    const tr_table_src = [
        n.g2, n.g2, n.c3, n.g2, n.c3, n.g2, n.d3, n.g2,
        n.g2, n.c3, n.g2, n.d3, n.g2, n.c3, n.g2, n.d3,
    ];

    const tr_table = tr_table_src;
    const durations_tr = tr_table_src.map(x => dur(4));
    const volumes_tr = tr_table_src.map(x => vol(15));

    const hi_hat = utils.mkNote(44100);
    const hi_hat_dur = 1;
    const base_drum = utils.mkNote(22000);
    const base_drum_dur = 4;

    const noise_table_src = [
        hi_hat, hi_hat, base_drum, hi_hat, hi_hat, base_drum,
    ];

    const noise_table = noise_table_src.flatMap(x => [x, n.blank]);
    const durations_ns = noise_table_src.flatMap((x, i) =>
        (i + 1) % 3 == 0
            ? [base_drum_dur, dur(4) - base_drum_dur]
            : [hi_hat_dur, dur(2) - hi_hat_dur]
    );
    const volumes_ns = noise_table_src.flatMap(x => [vol(15), vol(0)]);
    const ns_modes = noise_table_src.flatMap((x, i) =>
        (i + 1) % 3 == 0
            ? [0x80, 0x00]
            : [0x80, 0x00]
    );

    return asm`
${utils.noteTable("SQ1", sq1_table)}
${utils.noteTable("SQ2", sq2_table)}
${utils.noteTable("TR", tr_table)}
${utils.noteTable("NS", noise_table)}
music_notes_duration_sq:
    byte ${durations_sq.join(', ')}
music_notes_duration_tr:
    byte ${durations_tr.join(', ')}
music_notes_duration_ns:
    byte ${durations_ns.join(', ')}
music_notes_volume_sq:
    byte ${volumes_sq.join(', ')}
music_notes_volume_tr:
    byte ${volumes_tr.join(', ')}
music_notes_volume_ns:
    byte ${volumes_ns.join(', ')}
music_notes_ns_mode:
    byte ${ns_modes.join(', ')}`;
};

const data = () => asm`
music_timer_sq: .byte $01
music_timer_tr: .byte $01
music_timer_ns: .byte $01
music_pitch_timer: .byte $01
music_state_sq: .word $00FF
music_state_tr: .word $00FF
music_state_ns: .word $00FF
${generateTables()}
`;

export { instructions, data };
