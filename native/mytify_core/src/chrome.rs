//! Windows window chrome for the desktop app: the title bar is part of the app (no
//! separate system bar) with real Windows caption buttons and Snap Layouts, a tray icon
//! with its menu and notifications, and a single running instance. Everything runs on
//! the UI thread (window procedures and the event loop share it).
use serde_json::{json, Value};
use std::{cell::RefCell, ffi::c_void};
use tao::event_loop::EventLoopProxy;
use windows_sys::Win32::{
    Foundation::{COLORREF, GetLastError, ERROR_ALREADY_EXISTS, HWND, POINT, RECT},
    Graphics::{
        Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE},
        Gdi::{
            BeginPaint, CreateBitmap, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint, FillRect, InvalidateRect,
            SelectObject, SetBkMode, SetTextColor, CLEARTYPE_QUALITY, DEFAULT_CHARSET, DT_CENTER, DT_SINGLELINE, DT_VCENTER, FW_NORMAL,
            HFONT, PAINTSTRUCT, TRANSPARENT,
        },
    },
    System::{LibraryLoader::GetModuleHandleW, Threading::CreateMutexW},
    UI::{
        HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi},
        Input::KeyboardAndMouse::{
            ReleaseCapture, SendInput, SetCapture, TrackMouseEvent, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, TME_LEAVE,
            TRACKMOUSEEVENT, VK_LWIN,
        },
        Shell::{
            DefSubclassProc, SetCurrentProcessExplicitAppUserModelID, SetWindowSubclass, Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE,
            NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
        },
        WindowsAndMessaging::{
            AllowSetForegroundWindow, AppendMenuW, CreateIconIndirect, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
            GetClientRect, GetCursorPos, GetForegroundWindow, GetSystemMenu, GetWindowLongPtrW, IsIconic, IsWindowVisible, IsZoomed, KillTimer,
            LoadCursorW, PostMessageW, RegisterClassExW, RegisterWindowMessageW, SendMessageW, SetCursor, SetForegroundWindow,
            SetLayeredWindowAttributes, SetTimer, SetWindowLongPtrW, SetWindowPos, TrackPopupMenu, GetWindow, ASFW_ANY, GWL_STYLE,
            GW_CHILD, GW_HWNDNEXT, HICON, HTTOP, HTTOPLEFT, HTTOPRIGHT, HWND_BROADCAST, HWND_TOP, ICONINFO, IDC_ARROW, IDC_SIZENS, IDC_SIZENESW,
            IDC_SIZENWSE, LWA_ALPHA, MF_SEPARATOR, MF_STRING, NCCALCSIZE_PARAMS, SC_CLOSE, SM_CXPADDEDBORDER, SM_CYSIZEFRAME, SWP_HIDEWINDOW,
            SWP_NOACTIVATE, SWP_SHOWWINDOW, TPM_RETURNCMD, TPM_RIGHTBUTTON, WM_ACTIVATE,
            WM_APP, WM_CONTEXTMENU, WM_DPICHANGED, WM_ERASEBKGND, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP,
            WM_MOUSEMOVE, WM_NCCALCSIZE, WM_NCLBUTTONDOWN, WM_PAINT, WM_RBUTTONUP, WM_SETCURSOR, WM_SIZE, WM_SYSCOMMAND, WM_TIMER,
            WNDCLASSEXW, WS_CAPTION, WS_CHILD, WS_CLIPSIBLINGS, WS_EX_LAYERED,
        },
    },
};

const SUBCLASS: usize = 0x4d7a;
const TRAY_MSG: u32 = WM_APP + 0x31;
const SNAP_TIMER: usize = 0x5a1;
const TRAY_ID: u32 = 1;
const WM_MOUSELEAVE: u32 = 0x02a3;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Button {
    Min,
    Max,
    Close,
}

struct State {
    parent: HWND,
    strip: HWND,
    caption: HWND,
    bg: COLORREF,
    fg: COLORREF,
    hover: Option<Button>,
    pressed: Option<Button>,
    active: bool,
    /// Integrated title bar in use (normal window; not the mini player or full screen).
    on: bool,
    font: HFONT,
    font_dpi: u32,
    fluent: bool,
    icon: HICON,
    tray: bool,
    activate: u32,
    taskbar_created: u32,
    proxy: EventLoopProxy<Value>,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    STATE.with(|s| s.try_borrow_mut().ok().and_then(|mut s| s.as_mut().map(f)))
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn copy_into(dst: &mut [u16], s: &str) {
    for (i, c) in s.encode_utf16().take(dst.len() - 1).enumerate() {
        dst[i] = c;
    }
}

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    r as u32 | (g as u32) << 8 | (b as u32) << 16
}

fn parts(c: COLORREF) -> (f32, f32, f32) {
    ((c & 0xff) as f32, ((c >> 8) & 0xff) as f32, ((c >> 16) & 0xff) as f32)
}

/// `a` over `b` with weight `t`.
fn mix(a: COLORREF, b: COLORREF, t: f32) -> COLORREF {
    let (ar, ag, ab) = parts(a);
    let (br, bg, bb) = parts(b);
    let m = |x: f32, y: f32| (x * t + y * (1.0 - t)).round().clamp(0.0, 255.0) as u8;
    rgb(m(ar, br), m(ag, bg), m(ab, bb))
}

/// "#rrggbb" → COLORREF.
fn parse(hex: &str) -> Option<COLORREF> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() < 6 {
        return None;
    }
    let v = u32::from_str_radix(&h[h.len() - 6..], 16).ok()?;
    Some(rgb((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

fn dpi(hwnd: HWND) -> u32 {
    let d = unsafe { GetDpiForWindow(hwnd) };
    if d == 0 { 96 } else { d }
}

fn scaled(px: f32, dpi: u32) -> i32 {
    (px * dpi as f32 / 96.0).round() as i32
}

fn zoomed(hwnd: HWND) -> bool {
    unsafe { IsZoomed(hwnd) != 0 }
}

fn has_caption(hwnd: HWND) -> bool {
    unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) as u32 & WS_CAPTION == WS_CAPTION }
}

/// App icon for the tray, from the PNG shipped in the binary (straight alpha BGRA).
fn app_icon() -> HICON {
    let Ok(img) = image::load_from_memory(include_bytes!("../../../assets/mytify-icon.png")) else {
        return std::ptr::null_mut();
    };
    let img = image::imageops::resize(&img.to_rgba8(), 32, 32, image::imageops::FilterType::Lanczos3);
    let mut bgra = Vec::with_capacity(32 * 32 * 4);
    for p in img.pixels() {
        bgra.extend_from_slice(&[p[2], p[1], p[0], p[3]]);
    }
    let mask = vec![0u8; 32 * 32 / 8];
    unsafe {
        let color = CreateBitmap(32, 32, 1, 32, bgra.as_ptr().cast());
        let mono = CreateBitmap(32, 32, 1, 1, mask.as_ptr().cast());
        let info = ICONINFO { fIcon: 1, xHotspot: 0, yHotspot: 0, hbmMask: mono, hbmColor: color };
        let icon = CreateIconIndirect(&info);
        DeleteObject(color);
        DeleteObject(mono);
        icon
    }
}

/// Claims the single desktop instance. A second start asks the running one to come to
/// the front and returns false.
pub fn single_instance() -> bool {
    unsafe {
        let name = wide("Local\\Mytify.Desktop");
        let mutex = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
        if !mutex.is_null() && GetLastError() == ERROR_ALREADY_EXISTS {
            AllowSetForegroundWindow(ASFW_ANY);
            let msg = RegisterWindowMessageW(wide("Mytify.Activate").as_ptr());
            PostMessageW(HWND_BROADCAST, msg, 0, 0);
            return false;
        }
        // The mutex handle stays open as long as the process runs.
        let _ = mutex;
    }
    true
}

/// Taskbar grouping, the media flyout and notifications name the app the same way.
pub fn app_id() {
    unsafe {
        SetCurrentProcessExplicitAppUserModelID(wide("Kanik.Mytify").as_ptr());
    }
}

fn register(name: &str, proc: unsafe extern "system" fn(HWND, u32, usize, isize) -> isize) -> Vec<u16> {
    let class = wide(name);
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(proc),
            hInstance: GetModuleHandleW(std::ptr::null()),
            hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
            lpszClassName: class.as_ptr(),
            ..Default::default()
        };
        RegisterClassExW(&wc);
    }
    class
}

/// Installs the integrated title bar and the tray icon on the main window.
pub fn install(parent: *mut c_void, proxy: EventLoopProxy<Value>) {
    let parent = parent as HWND;
    unsafe {
        let strip_class = register("MytifyResizeEdge", strip_proc);
        let caption_class = register("MytifyCaption", caption_proc);
        let hinst = GetModuleHandleW(std::ptr::null());
        let strip = CreateWindowExW(
            WS_EX_LAYERED,
            strip_class.as_ptr(),
            std::ptr::null(),
            WS_CHILD | WS_CLIPSIBLINGS,
            0,
            0,
            0,
            0,
            parent,
            std::ptr::null_mut(),
            hinst,
            std::ptr::null(),
        );
        // Practically invisible, but it still takes the mouse for resizing from the top edge.
        SetLayeredWindowAttributes(strip, 0, 1, LWA_ALPHA);
        let caption = CreateWindowExW(
            0,
            caption_class.as_ptr(),
            std::ptr::null(),
            WS_CHILD | WS_CLIPSIBLINGS,
            0,
            0,
            0,
            0,
            parent,
            std::ptr::null_mut(),
            hinst,
            std::ptr::null(),
        );
        let dark: i32 = 1;
        DwmSetWindowAttribute(parent, DWMWA_USE_IMMERSIVE_DARK_MODE as u32, (&dark as *const i32).cast(), 4);
        let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
        let fluent = std::path::Path::new(&windir).join("Fonts").join("SegoeIcons.ttf").exists();
        STATE.with(|s| {
            *s.borrow_mut() = Some(State {
                parent,
                strip,
                caption,
                bg: rgb(12, 13, 15),
                fg: rgb(255, 255, 255),
                hover: None,
                pressed: None,
                active: true,
                on: true,
                font: std::ptr::null_mut(),
                font_dpi: 0,
                fluent,
                icon: app_icon(),
                tray: false,
                activate: RegisterWindowMessageW(wide("Mytify.Activate").as_ptr()),
                taskbar_created: RegisterWindowMessageW(wide("TaskbarCreated").as_ptr()),
                proxy,
            })
        });
        SetWindowSubclass(parent, Some(parent_proc), SUBCLASS, 0);
        clip_webview(parent);
        // Recalculate the frame without the system title bar.
        SetWindowPos(parent, std::ptr::null_mut(), 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010);
    }
    tray_add();
    layout();
}

/// The web view's container must not paint over the caption buttons.
fn clip_webview(parent: HWND) {
    let ours = with(|s| (s.strip, s.caption)).unwrap_or((std::ptr::null_mut(), std::ptr::null_mut()));
    unsafe {
        let mut child = GetWindow(parent, GW_CHILD);
        while !child.is_null() {
            if child != ours.0 && child != ours.1 {
                let style = GetWindowLongPtrW(child, GWL_STYLE);
                SetWindowLongPtrW(child, GWL_STYLE, style | WS_CLIPSIBLINGS as isize);
            }
            child = GetWindow(child, GW_HWNDNEXT);
        }
    }
}

/// Places the caption buttons and the top resize edge.
fn layout() {
    let Some((parent, strip, caption, on)) = with(|s| (s.parent, s.strip, s.caption, s.on)) else { return };
    let d = dpi(parent);
    let mut rc = RECT::default();
    unsafe { GetClientRect(parent, &mut rc) };
    let (bw, bh) = (scaled(46.0, d), scaled(32.0, d));
    let show = on && has_caption(parent);
    let w = rc.right - rc.left;
    unsafe {
        SetWindowPos(
            caption,
            HWND_TOP,
            w - bw * 3,
            0,
            bw * 3,
            bh,
            SWP_NOACTIVATE | if show { SWP_SHOWWINDOW } else { SWP_HIDEWINDOW },
        );
        let edge = show && !zoomed(parent);
        SetWindowPos(
            strip,
            HWND_TOP,
            0,
            0,
            (w - bw * 3).max(0),
            scaled(5.0, d),
            SWP_NOACTIVATE | if edge { SWP_SHOWWINDOW } else { SWP_HIDEWINDOW },
        );
        InvalidateRect(caption, std::ptr::null(), 0);
    }
}

/// Title bar colours from the app (its theme), so the buttons sit on the same surface.
pub fn colors(v: &Value) {
    let bg = v["bg"].as_str().and_then(parse);
    let fg = v["fg"].as_str().and_then(parse);
    with(|s| {
        if let Some(c) = bg {
            s.bg = c;
        }
        if let Some(c) = fg {
            s.fg = c;
        }
    });
    if let Some(caption) = with(|s| s.caption) {
        unsafe { InvalidateRect(caption, std::ptr::null(), 0) };
    }
}

/// Normal window: integrated title bar on. Mini player and full screen: off.
pub fn enable(on: bool) {
    let parent = with(|s| {
        s.on = on;
        s.parent
    });
    if let Some(p) = parent {
        unsafe { SetWindowPos(p, std::ptr::null_mut(), 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010) };
    }
    layout();
}



/// The system window menu (restore, move, size, minimize, maximize, close) at the cursor.
pub fn system_menu() {
    let Some(p) = with(|s| s.parent) else { return };
    unsafe {
        let menu = GetSystemMenu(p, 0);
        if menu.is_null() {
            return;
        }
        let mut pt = POINT::default();
        GetCursorPos(&mut pt);
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, p, std::ptr::null());
        if cmd != 0 {
            PostMessageW(p, WM_SYSCOMMAND, cmd as usize, 0);
        }
    }
}

/// Asks the event loop to bring the window back (from the tray, minimized or behind
/// others); the window library keeps track of the state that way.
pub fn show() {
    send(json!({"action": "tray", "command": "show"}));
}

/// In front of other windows (after it was shown), restored if it was minimized.
/// Windows lets only the foreground thread hand the focus over, so the input of the
/// window in front is attached for the moment of the switch.
pub fn front() {
    use windows_sys::Win32::{
        System::Threading::{AttachThreadInput, GetCurrentThreadId},
        UI::WindowsAndMessaging::{BringWindowToTop, GetWindowThreadProcessId, ShowWindow, SW_RESTORE},
    };
    if let Some(p) = with(|s| s.parent) {
        unsafe {
            if IsIconic(p) != 0 {
                ShowWindow(p, SW_RESTORE);
            }
            let other = GetWindowThreadProcessId(GetForegroundWindow(), std::ptr::null_mut());
            let me = GetCurrentThreadId();
            let attached = other != 0 && other != me && AttachThreadInput(me, other, 1) != 0;
            BringWindowToTop(p);
            SetForegroundWindow(p);
            if attached {
                AttachThreadInput(me, other, 0);
            }
        }
    }
}

pub fn visible() -> bool {
    with(|s| unsafe { IsWindowVisible(s.parent) != 0 && IsIconic(s.parent) == 0 }).unwrap_or(true)
}

/// Whether the window is the one the user works in now (no notification needed then).
pub fn focused() -> bool {
    with(|s| unsafe { GetForegroundWindow() == s.parent && IsWindowVisible(s.parent) != 0 }).unwrap_or(false)
}

fn tray_data(s: &State) -> NOTIFYICONDATAW {
    let mut d = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: s.parent,
        uID: TRAY_ID,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: TRAY_MSG,
        hIcon: s.icon,
        ..Default::default()
    };
    copy_into(&mut d.szTip, "Mytify");
    d
}

fn tray_add() {
    with(|s| {
        let d = tray_data(s);
        s.tray = unsafe { Shell_NotifyIconW(NIM_ADD, &d) } != 0;
    });
}

pub fn tray_remove() {
    with(|s| {
        if s.tray {
            let d = tray_data(s);
            unsafe { Shell_NotifyIconW(NIM_DELETE, &d) };
            s.tray = false;
        }
    });
}

pub fn has_tray() -> bool {
    with(|s| s.tray).unwrap_or(false)
}

/// A Windows notification (shown as a toast) from the tray icon.
pub fn notify(title: &str, text: &str) {
    with(|s| {
        if !s.tray {
            return;
        }
        let mut d = tray_data(s);
        d.uFlags |= NIF_INFO;
        d.dwInfoFlags = NIIF_INFO;
        copy_into(&mut d.szInfoTitle, title);
        copy_into(&mut d.szInfo, text);
        unsafe { Shell_NotifyIconW(NIM_MODIFY, &d) };
    });
}

fn tray_menu(parent: HWND, playing: bool) {
    unsafe {
        let menu = CreatePopupMenu();
        let item = |id: usize, text: &str| {
            let t = wide(text);
            AppendMenuW(menu, MF_STRING, id, t.as_ptr());
        };
        item(1, "Pokaż Mytify");
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        item(2, if playing { "Pauza" } else { "Odtwarzaj" });
        item(3, "Następny");
        item(4, "Poprzedni");
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        item(5, "Zakończ Mytify");
        let mut pt = POINT::default();
        GetCursorPos(&mut pt);
        // The menu closes when clicking elsewhere only if the window is in front.
        SetForegroundWindow(parent);
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, parent, std::ptr::null());
        DestroyMenu(menu);
        let command = match cmd {
            1 => Some("show"),
            2 => Some("toggle"),
            3 => Some("next"),
            4 => Some("previous"),
            5 => Some("quit"),
            _ => None,
        };
        if let Some(c) = command {
            send(json!({"action": "tray", "command": c}));
        }
    }
}

fn send(v: Value) {
    if let Some(p) = with(|s| s.proxy.clone()) {
        let _ = p.send_event(v);
    }
}

// Playing state for the tray menu wording.
thread_local! {
    static PLAYING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
pub fn set_playing(playing: bool) {
    PLAYING.with(|p| p.set(playing));
}

unsafe extern "system" fn parent_proc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize, _id: usize, _data: usize) -> isize {
    let (on, activate, taskbar_created) = with(|s| (s.on, s.activate, s.taskbar_created)).unwrap_or((false, 0, 0));
    match msg {
        WM_NCCALCSIZE if wparam != 0 && on && has_caption(hwnd) => {
            // Keep the side and bottom frame (resizing, shadow, Snap), drop the title bar.
            let params = lparam as *mut NCCALCSIZE_PARAMS;
            let top = unsafe { (*params).rgrc[0].top };
            let result = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
            let d = dpi(hwnd);
            let frame = if zoomed(hwnd) {
                unsafe { GetSystemMetricsForDpi(SM_CYSIZEFRAME, d) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, d) }
            } else {
                0
            };
            unsafe { (*params).rgrc[0].top = top + frame };
            return result;
        }
        WM_SIZE | WM_DPICHANGED => {
            let r = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
            layout();
            return r;
        }
        WM_ACTIVATE => {
            let active = wparam & 0xffff != 0;
            if let Some(c) = with(|s| {
                s.active = active;
                s.caption
            }) {
                unsafe { InvalidateRect(c, std::ptr::null(), 0) };
            }
        }
        TRAY_MSG => {
            match lparam as u32 {
                WM_LBUTTONUP | WM_LBUTTONDBLCLK => {
                    if visible() && focused() {
                        send(json!({"action": "tray", "command": "minimize"}));
                    } else {
                        show();
                    }
                }
                WM_RBUTTONUP | WM_CONTEXTMENU => tray_menu(hwnd, PLAYING.with(|p| p.get())),
                _ => {}
            }
            return 0;
        }
        m if m != 0 && m == activate => {
            // Mytify started again while it sits in the tray: it opens as if started.
            send(json!({"action": "tray", "command": "launch"}));
            return 0;
        }
        m if m != 0 && m == taskbar_created => {
            // Explorer restarted: the tray icon has to be added again.
            with(|s| s.tray = false);
            tray_add();
        }
        _ => {}
    }
    unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
}

/// Top resize edge over the web view: Windows resizes as if the frame's top was grabbed.
unsafe extern "system" fn strip_proc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) -> isize {
    let edge = |hwnd: HWND| -> u32 {
        let mut pt = POINT::default();
        let mut rc = RECT::default();
        unsafe {
            GetCursorPos(&mut pt);
            windows_sys::Win32::Graphics::Gdi::ScreenToClient(hwnd, &mut pt);
            GetClientRect(hwnd, &mut rc);
        }
        let corner = scaled(10.0, dpi(hwnd));
        if pt.x < corner { HTTOPLEFT } else if pt.x > rc.right - corner { HTTOPRIGHT } else { HTTOP }
    };
    match msg {
        WM_SETCURSOR => {
            let cursor = match edge(hwnd) {
                HTTOPLEFT => IDC_SIZENWSE,
                HTTOPRIGHT => IDC_SIZENESW,
                _ => IDC_SIZENS,
            };
            unsafe { SetCursor(LoadCursorW(std::ptr::null_mut(), cursor)) };
            return 1;
        }
        WM_LBUTTONDOWN => {
            let code = edge(hwnd);
            if let Some(p) = with(|s| s.parent) {
                let mut pt = POINT::default();
                unsafe {
                    GetCursorPos(&mut pt);
                    ReleaseCapture();
                    SendMessageW(p, WM_NCLBUTTONDOWN, code as usize, ((pt.y as isize) << 16) | (pt.x as isize & 0xffff));
                }
            }
            return 0;
        }
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            unsafe {
                BeginPaint(hwnd, &mut ps);
                EndPaint(hwnd, &ps);
            }
            return 0;
        }
        _ => {}
    }
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

fn button_at(hwnd: HWND, x: i32) -> Option<Button> {
    let mut rc = RECT::default();
    unsafe { GetClientRect(hwnd, &mut rc) };
    let w = (rc.right - rc.left) / 3;
    if w <= 0 || x < 0 {
        return None;
    }
    match x / w {
        0 => Some(Button::Min),
        1 => Some(Button::Max),
        2 => Some(Button::Close),
        _ => None,
    }
}

/// Win+Z: the Windows 11 Snap Layouts flyout for this window.
fn snap_layouts() {
    let key = |vk: u16, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
        },
    };
    let inputs = [key(VK_LWIN, false), key(b'Z' as u16, false), key(b'Z' as u16, true), key(VK_LWIN, true)];
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}

fn paint_caption(hwnd: HWND) {
    let Some((parent, bg, fg, hover, pressed, active, fluent)) =
        with(|s| (s.parent, s.bg, s.fg, s.hover, s.pressed, s.active, s.fluent))
    else {
        return;
    };
    let d = dpi(hwnd);
    let font = with(|s| {
        if s.font.is_null() || s.font_dpi != d {
            unsafe {
                if !s.font.is_null() {
                    DeleteObject(s.font);
                }
                let face = wide(if s.fluent { "Segoe Fluent Icons" } else { "Segoe MDL2 Assets" });
                s.font = CreateFontW(
                    -scaled(10.0, d),
                    0,
                    0,
                    0,
                    FW_NORMAL as i32,
                    0,
                    0,
                    0,
                    DEFAULT_CHARSET as u32,
                    0,
                    0,
                    CLEARTYPE_QUALITY as u32,
                    0,
                    face.as_ptr(),
                );
            }
            s.font_dpi = d;
        }
        s.font
    })
    .unwrap_or(std::ptr::null_mut());
    let _ = fluent;
    let mut ps = PAINTSTRUCT::default();
    unsafe {
        let hdc = BeginPaint(hwnd, &mut ps);
        let mut rc = RECT::default();
        GetClientRect(hwnd, &mut rc);
        let w = (rc.right - rc.left) / 3;
        let max_glyph = if zoomed(parent) { "\u{E923}" } else { "\u{E922}" };
        let old = SelectObject(hdc, font);
        SetBkMode(hdc, TRANSPARENT as i32);
        for (i, (b, glyph)) in [(Button::Min, "\u{E921}"), (Button::Max, max_glyph), (Button::Close, "\u{E8BB}")].into_iter().enumerate() {
            let mut r = RECT { left: rc.left + w * i as i32, top: rc.top, right: if i == 2 { rc.right } else { rc.left + w * (i as i32 + 1) }, bottom: rc.bottom };
            let hot = hover == Some(b);
            let down = pressed == Some(b) && hot;
            let (fill, text) = match (b, hot, down) {
                (Button::Close, true, false) => (rgb(196, 43, 28), rgb(255, 255, 255)),
                (Button::Close, true, true) => (rgb(200, 64, 50), rgb(255, 255, 255)),
                (_, true, false) => (mix(fg, bg, 0.09), fg),
                (_, true, true) => (mix(fg, bg, 0.05), mix(fg, bg, 0.8)),
                _ => (bg, if active { fg } else { mix(fg, bg, 0.45) }),
            };
            let brush = CreateSolidBrush(fill);
            FillRect(hdc, &r, brush);
            DeleteObject(brush);
            SetTextColor(hdc, text);
            let g = wide(glyph);
            DrawTextW(hdc, g.as_ptr(), -1, &mut r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        SelectObject(hdc, old);
        EndPaint(hwnd, &ps);
    }
}

unsafe extern "system" fn caption_proc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) -> isize {
    let x = (lparam & 0xffff) as i16 as i32;
    match msg {
        WM_PAINT => {
            paint_caption(hwnd);
            return 0;
        }
        WM_ERASEBKGND => return 1,
        WM_MOUSEMOVE => {
            let now = button_at(hwnd, x);
            let changed = with(|s| {
                let c = s.hover != now;
                s.hover = now;
                c
            })
            .unwrap_or(false);
            if changed {
                unsafe {
                    let mut t = TRACKMOUSEEVENT { cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32, dwFlags: TME_LEAVE, hwndTrack: hwnd, dwHoverTime: 0 };
                    TrackMouseEvent(&mut t);
                    InvalidateRect(hwnd, std::ptr::null(), 0);
                    if now == Some(Button::Max) {
                        SetTimer(hwnd, SNAP_TIMER, 550, None);
                    } else {
                        KillTimer(hwnd, SNAP_TIMER);
                    }
                }
            }
            return 0;
        }
        WM_MOUSELEAVE => {
            with(|s| s.hover = None);
            unsafe {
                KillTimer(hwnd, SNAP_TIMER);
                InvalidateRect(hwnd, std::ptr::null(), 0);
            }
            return 0;
        }
        WM_TIMER if wparam == SNAP_TIMER => {
            unsafe { KillTimer(hwnd, SNAP_TIMER) };
            let still = with(|s| s.hover == Some(Button::Max) && s.pressed.is_none()).unwrap_or(false);
            if still {
                snap_layouts();
            }
            return 0;
        }
        WM_LBUTTONDOWN => {
            let b = button_at(hwnd, x);
            with(|s| s.pressed = b);
            unsafe {
                KillTimer(hwnd, SNAP_TIMER);
                SetCapture(hwnd);
                InvalidateRect(hwnd, std::ptr::null(), 0);
            }
            return 0;
        }
        WM_LBUTTONUP => {
            let b = button_at(hwnd, x);
            let mut rc = RECT::default();
            unsafe { GetClientRect(hwnd, &mut rc) };
            let y = ((lparam >> 16) & 0xffff) as i16 as i32;
            let inside = y >= rc.top && y < rc.bottom;
            let (pressed, parent) = with(|s| {
                let p = s.pressed.take();
                (p, s.parent)
            })
            .unwrap_or((None, std::ptr::null_mut()));
            unsafe {
                ReleaseCapture();
                InvalidateRect(hwnd, std::ptr::null(), 0);
            }
            if inside && pressed.is_some() && pressed == b {
                match b {
                    Some(Button::Min) => send(json!({"action": "tray", "command": "minimize"})),
                    Some(Button::Max) => send(json!({"action": "tray", "command": "maximize"})),
                    Some(Button::Close) => unsafe {
                        PostMessageW(parent, WM_SYSCOMMAND, SC_CLOSE as usize, 0);
                    },
                    None => {}
                }
            }
            return 0;
        }
        WM_RBUTTONUP => {
            system_menu();
            return 0;
        }
        _ => {}
    }
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colours() {
        assert_eq!(parse("#0c0d0f"), Some(rgb(12, 13, 15)));
        assert_eq!(parse("ff0c0d0f"), Some(rgb(12, 13, 15)));
        assert_eq!(parse("#fff"), None);
        assert_eq!(mix(rgb(255, 255, 255), rgb(0, 0, 0), 0.5), rgb(128, 128, 128));
    }
}
