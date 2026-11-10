# Enjin Arch dotfiles

Portable personal Arch Linux setup for Hyprland 0.55+, Quickshell, Kitty,
Rofi, dynamic themes, wallpaper selection, audio controls, and a Zsh/Starship
shell. The configuration is based on the 43PR setup and includes Enjin's
custom keybindings and fixes.

## Install

Use this on a fresh Arch-based installation (Arch, EndeavourOS, CachyOS,
Manjaro, and similar):

```bash
sudo pacman -S --needed git
git clone <your-repository-url> ~/Enjin-Arch-dotfiles
cd ~/Enjin-Arch-dotfiles
chmod +x install.sh
./install.sh
```

If you already copied this folder to the laptop, just run `./install.sh` from
inside it. The script installs packages listed in `packages.txt`, bootstraps
`yay` when needed for AUR packages, links the configuration into `~/.config`,
sets up PipeWire and power profiles, creates the wallpaper directories, and
generates the first theme.

## Safety and backups

- The installer refuses to run as root.
- Existing files that would be replaced are moved to
  `~/.config-backups/<timestamp>/`; they are not deleted.
- Configuration files are symlinked to this repository so future edits are
  preserved in the dotfiles folder. Keep the folder in place after installing;
  if you move it, run `./install.sh` again to repoint the links.
- Runtime state, generated colors, caches, credentials, recordings, and
  personal wallpapers are not bundled.
- `spicetify/config-xpui.ini` is installed as a copy so its Spotify preference
  path is rendered for the current user instead of using this laptop's path.

Run `./install.sh --help` to see the installer usage.

## Main keybindings

| Shortcut | Action |
| --- | --- |
| `Super + Return` | Open Kitty terminal |
| `Super + D` | Application launcher |
| `Super + E` | File manager |
| `Super + B` | Default browser |
| `Super + W` | Wallpaper selector |
| `Super + T` | Theme selector |
| `Ctrl + Left/Right` | Previous/next workspace |
| `Super + Left/Right/Up/Down` | Focus a window in that direction |
| `Ctrl + Shift + Left/Right/Up/Down` | Move the focused window in that direction |
| `Super + Shift + Left/Right/Up/Down` | Resize the focused tiled window |
| `Ctrl + Shift + P` | Power menu |

Hold a resize shortcut to repeat it in small increments. Monitor rules use a
preferred-mode catch-all, so the setup can start on different laptop displays
without hardcoded output names.

## Updating the setup

After changing files in the repository, restart or reload the affected
application. Hyprland can be reloaded with:

```bash
hyprctl reload
```

Review `packages.txt` before installing on hardware with a different GPU. The
optional `nvidia-utils` and `intel-gpu-tools` packages are intentionally not
enabled by default.
