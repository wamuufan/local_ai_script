#!/usr/bin/env bash
# ==============================================================================
#  bin/tools/viewer.sh — WebKitGTK Native App Viewer Tool Module
# ==============================================================================

set -euo pipefail

install_viewer() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local bin_dir="${home_dir}/.local/bin"
    local viewer_bin="${bin_dir}/localai-viewer"

    log_header "Installing Native WebKitGTK Viewer → ${container}"

    steps_begin 3

    log_step "Installing WebKitGTK and PyGObject system packages..."
    distrobox enter "${container}" -- bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update
        if apt-cache show gir1.2-webkit2-4.1 &>/dev/null; then
            sudo apt-get install -y python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1
        elif apt-cache show gir1.2-webkit-6.0 &>/dev/null; then
            sudo apt-get install -y python3 python3-gi gir1.2-gtk-4.0 gir1.2-webkit-6.0
        else
            echo 'ERROR: Neither gir1.2-webkit2-4.1 nor gir1.2-webkit-6.0 found in apt repositories!' >&2
            exit 1
        fi
    "

    log_step "Creating standalone viewer launcher script..."
    mkdir -p "${bin_dir}"

    cat << 'EOF' > "${viewer_bin}"
#!/usr/bin/env python3
"""
localai-viewer — Ultra-lightweight native WebKitGTK kiosk/app window
No address bar, no navigation buttons, no Ctrl+S web-save dialog.
Automatically detects and sets window & taskbar icon from web app favicon.
"""
import sys
import os

url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
title = sys.argv[2] if len(sys.argv) > 2 else "LocalAI App"
app_id = sys.argv[3] if len(sys.argv) > 3 else "localai-viewer"
initial_icon = sys.argv[4] if len(sys.argv) > 4 else None

import gi
gi.require_version('GLib', '2.0')
from gi.repository import GLib

# Set Wayland app_id (must match .desktop filename for KDE/GNOME taskbar icon)
GLib.set_prgname(app_id)
GLib.set_application_name(title)

gtk_version = None
for wk_ver in ['4.1', '4.0']:
    try:
        gi.require_version('WebKit2', wk_ver)
        gi.require_version('Gtk', '3.0')
        gtk_version = 3
        break
    except (ValueError, AttributeError):
        pass

if not gtk_version:
    try:
        gi.require_version('WebKit', '6.0')
        gi.require_version('Gtk', '4.0')
        gtk_version = 4
    except (ValueError, AttributeError):
        sys.stderr.write("Error: Required WebKitGTK libraries (gir1.2-webkit2-4.1 or gir1.2-webkit-6.0) not found.\n")
        sys.exit(1)

if gtk_version == 3:
    from gi.repository import Gtk, Gdk, WebKit2, GLib

    win = Gtk.Window(title=title)
    win.set_default_size(1440, 920)
    win.set_position(Gtk.WindowPosition.CENTER)
    win.set_wmclass(app_id, app_id)
    win.set_role(app_id)

    # Set initial icon if provided
    if initial_icon and os.path.isfile(initial_icon):
        try:
            win.set_icon_from_file(initial_icon)
        except Exception:
            pass

    view = WebKit2.WebView()
    settings = view.get_settings()
    settings.set_enable_webgl(True)
    settings.set_enable_smooth_scrolling(True)
    settings.set_enable_developer_extras(False)
    settings.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.ALWAYS)

    # Automatically set window & taskbar icon when web app favicon loads
    def on_favicon_changed(web_view, pspec):
        try:
            surface = web_view.get_favicon()
            if surface:
                w = surface.get_width()
                h = surface.get_height()
                if w > 0 and h > 0:
                    pixbuf = Gdk.pixbuf_get_from_surface(surface, 0, 0, w, h)
                    if pixbuf:
                        win.set_icon(pixbuf)
        except Exception:
            pass

    view.connect("notify::favicon", on_favicon_changed)

    # Keyboard shortcuts helper
    def on_key_press(widget, event):
        keyval = event.keyval
        state = event.state

        # F11: Fullscreen toggle
        if keyval == Gdk.KEY_F11:
            if getattr(win, 'is_fullscreen', False):
                win.unfullscreen()
                win.is_fullscreen = False
            else:
                win.fullscreen()
                win.is_fullscreen = True
            return True

        # F5 or Ctrl+R: Reload
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
        if keyval == Gdk.KEY_F5 or (ctrl and keyval in (Gdk.KEY_r, Gdk.KEY_R)):
            view.reload()
            return True

        # Ctrl + / Ctrl - : Zoom
        if ctrl and keyval in (Gdk.KEY_plus, Gdk.KEY_equal, Gdk.KEY_KP_Add):
            view.set_zoom_level(view.get_zoom_level() + 0.1)
            return True
        if ctrl and keyval in (Gdk.KEY_minus, Gdk.KEY_KP_Subtract):
            view.set_zoom_level(max(0.2, view.get_zoom_level() - 0.1))
            return True
        if ctrl and keyval in (Gdk.KEY_0, Gdk.KEY_KP_0):
            view.set_zoom_level(1.0)
            return True

        # Pass all other keys (including Ctrl+S) directly to the web view
        return False

    win.is_fullscreen = False
    win.connect("key-press-event", on_key_press)
    win.connect("destroy", Gtk.main_quit)

    win.add(view)
    view.load_uri(url)
    win.show_all()
    Gtk.main()

else:
    # GTK 4 + WebKit 6.0
    from gi.repository import Gtk, Gdk, WebKit, GLib

    clean_id = "".join(c if c.isalnum() or c == "-" else "-" for c in app_id).strip("-") or "viewer"
    app = Gtk.Application(application_id=f"com.localai.{clean_id}")

    def on_activate(application):
        win = Gtk.ApplicationWindow(application=application, title=title)
        win.set_default_size(1440, 920)
        win._is_fullscreen = False

        view = WebKit.WebView()
        settings = view.get_settings()
        settings.set_enable_webgl(True)
        settings.set_enable_smooth_scrolling(True)
        settings.set_enable_developer_extras(False)

        # Keyboard shortcuts helper
        key_controller = Gtk.EventControllerKey.new()

        def on_key_pressed(controller, keyval, keycode, state):
            # F11: Fullscreen toggle
            if keyval == Gdk.KEY_F11:
                is_fs = win.is_fullscreen() if callable(getattr(win, "is_fullscreen", None)) else getattr(win, "_is_fullscreen", False)
                if is_fs:
                    win.unfullscreen()
                    win._is_fullscreen = False
                else:
                    win.fullscreen()
                    win._is_fullscreen = True
                return True

            # F5 or Ctrl+R: Reload
            ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
            if keyval == Gdk.KEY_F5 or (ctrl and keyval in (Gdk.KEY_r, Gdk.KEY_R)):
                view.reload()
                return True

            # Ctrl + / Ctrl - : Zoom
            if ctrl and keyval in (Gdk.KEY_plus, Gdk.KEY_equal, Gdk.KEY_KP_Add):
                view.set_zoom_level(view.get_zoom_level() + 0.1)
                return True
            if ctrl and keyval in (Gdk.KEY_minus, Gdk.KEY_KP_Subtract):
                view.set_zoom_level(max(0.2, view.get_zoom_level() - 0.1))
                return True
            if ctrl and keyval in (Gdk.KEY_0, Gdk.KEY_KP_0):
                view.set_zoom_level(1.0)
                return True

            # Pass all other keys (including Ctrl+S) directly to the web view
            return False

        key_controller.connect("key-pressed", on_key_pressed)
        win.add_controller(key_controller)

        view.load_uri(url)
        win.set_child(view)
        win.present()

    app.connect("activate", on_activate)
    app.run(None)
EOF

    chmod +x "${viewer_bin}"

    log_step "Verifying WebKitGTK installation in '${container}'..."
    if ! distrobox enter "${container}" -- python3 -c '
import gi, sys
for v in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", v); gi.require_version("Gtk", "3.0"); from gi.repository import Gtk, WebKit2; sys.exit(0)
    except (ValueError, AttributeError, ImportError):
        pass
try:
    gi.require_version("WebKit", "6.0"); gi.require_version("Gtk", "4.0"); from gi.repository import Gtk, WebKit; sys.exit(0)
except (ValueError, AttributeError, ImportError):
    sys.exit(1)
' &>/dev/null; then
        die "WebKitGTK verification failed. Installation may be incomplete."
    fi
    steps_end

    log_success "Native WebKitGTK Viewer installed successfully in '${container}'."
    log_info    "Launcher   : ~/.local/bin/localai-viewer"
    log_info    "Open tool  : localai.sh open ${container}:<tool>"
}

is_installed_viewer() {
    local home_dir="${BASE_DIR}/$1"
    [[ -x "${home_dir}/.local/bin/localai-viewer" ]]
}

update_viewer() {
    local container="$1"
    log_header "Updating Viewer → ${container}"
    install_viewer "${container}"
}

uninstall_viewer() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"

    log_header "Uninstalling Viewer ← ${container}"
    steps_begin 1
    log_step "Removing Viewer files..."
    run_with_spinner "Removing viewer files" bash -c "
        rm -f '${home_dir}/.local/bin/localai-viewer'
        rm -f '${HOME}/.local/share/applications/localai-${container}-'*.desktop
        update-desktop-database '${HOME}/.local/share/applications' 2>/dev/null || true
    "
    steps_end
    log_success "Viewer uninstalled from '${container}'."
}

start_viewer() {
    local container="$1"
    local target_url="${2:-http://localhost:8188}"
    local title="${3:-LocalAI App}"
    local app_id="${4:-localai-viewer}"
    local icon_path="${5:-}"

    if ! is_installed_viewer "${container}"; then
        log_info "Viewer not installed in '${container}'. Installing automatically..."
        install_viewer "${container}"
    fi

    log_info "Launching WebKitGTK Viewer for '${title}' (${target_url})..."
    nohup distrobox enter "${container}" -- bash -c 'exec "$HOME/.local/bin/localai-viewer" "$1" "$2" "$3" "$4"' _ "${target_url}" "${title}" "${app_id}" "${icon_path}" >/dev/null 2>&1 &
}

stop_viewer() {
    local container="$1"
    distrobox enter "${container}" -- pkill -f "localai-viewer" 2>/dev/null || true
    log_success "Viewer closed."
}

ensure_viewer_desktop_entry() {
    local container="$1"
    local tool="$2"
    local title="${3:-${tool}}"
    local home_dir="${BASE_DIR}/${container}"

    local icon_dir="${HOME}/.local/share/icons/localai"
    local app_dir="${HOME}/.local/share/applications"
    mkdir -p "${icon_dir}" "${app_dir}"

    local target_icon="${icon_dir}/${tool}.png"
    if [[ ! -f "${target_icon}" ]]; then
        local found_icon=""
        case "${tool}" in
            comfyui)
                found_icon="$(find "${home_dir}/comfyui" -name "comfy-icon-192.png" 2>/dev/null | head -n 1)"
                [[ -z "${found_icon}" ]] && found_icon="$(find "${home_dir}/comfyui" -name "favicon.ico" 2>/dev/null | head -n 1)"
                ;;
            openwebui)
                found_icon="$(find "${home_dir}/.openwebui" -name "logo.png" 2>/dev/null | head -n 1)"
                [[ -z "${found_icon}" ]] && found_icon="$(find "${home_dir}/.openwebui" -name "favicon.png" 2>/dev/null | head -n 1)"
                ;;
            iopaint)
                found_icon="$(find "${home_dir}/iopaint" -name "*.png" 2>/dev/null | head -n 1)"
                ;;
        esac

        if [[ -n "${found_icon}" && -f "${found_icon}" ]]; then
            cp "${found_icon}" "${target_icon}" 2>/dev/null || true
        fi
    fi

    local desktop_icon="applications-science"
    if [[ -f "${target_icon}" ]]; then
        desktop_icon="${target_icon}"
    fi

    local desktop_file="${app_dir}/localai-${container}-${tool}.desktop"
    cat << EOF > "${desktop_file}"
[Desktop Entry]
Type=Application
Name=${title} (${container})
GenericName=AI Application
Exec="${SCRIPT_DIR}/localai.sh" open ${container}:${tool}
Path=${SCRIPT_DIR}
Icon=${desktop_icon}
StartupWMClass=localai-${container}-${tool}
Terminal=false
NoDisplay=false
StartupNotify=true
Categories=Graphics;Development;
Keywords=AI;${tool};
EOF
    if command -v kbuildsycoca6 &>/dev/null; then
        kbuildsycoca6 2>/dev/null || true
    elif command -v update-desktop-database &>/dev/null; then
        update-desktop-database "${app_dir}" 2>/dev/null || true
    fi
}
