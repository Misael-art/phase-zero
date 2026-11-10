-- Optional Hyprland 0.56+ overlay. Load after your normal Hyprland settings.
hl.config({
    general = { layout = "master" },
    master = { mfact = 0.62, new_status = "slave" },
})

hl.bind("SUPER + SHIFT + Return", hl.dsp.exec_cmd("gtk-launch phasezero-vibe-code"))

hl.window_rule({
    name = "phasezero-vibe-code-launcher",
    match = { class = "^phasezero-vibe-code$" },
    float = true,
    center = true,
})
