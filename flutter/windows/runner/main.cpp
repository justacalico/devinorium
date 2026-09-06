#include <cstdlib>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

struct FindWindowData {
  HWND hwnd;
};

static BOOL CALLBACK FindDevinoriumWindow(HWND hwnd, LPARAM lParam) {
  wchar_t title[256];
  wchar_t class_name[256];
  if (GetWindowTextW(hwnd, title, 256) > 0 &&
      GetClassNameW(hwnd, class_name, 256) > 0) {
    if (wcscmp(title, L"Devinorium") == 0 &&
        wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0 &&
        IsWindowVisible(hwnd)) {
      auto* data = reinterpret_cast<FindWindowData*>(lParam);
      data->hwnd = hwnd;
      return FALSE;
    }
  }
  return TRUE;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE mutex =
      CreateMutexW(nullptr, TRUE, L"devinorium_single_instance_mutex");
  if (mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(mutex);

    // The first instance may still be starting up and not have a visible
    // window yet, so retry briefly before giving up.
    FindWindowData data{nullptr};
    for (int attempt = 0; attempt < 30 && data.hwnd == nullptr; ++attempt) {
      EnumWindows(FindDevinoriumWindow, reinterpret_cast<LPARAM>(&data));
      if (data.hwnd == nullptr) {
        Sleep(100);
      }
    }
    if (data.hwnd != nullptr) {
      if (IsIconic(data.hwnd)) {
        WINDOWPLACEMENT placement{};
        placement.length = sizeof(placement);
        if (GetWindowPlacement(data.hwnd, &placement) &&
            (placement.flags & WPF_RESTORETOMAXIMIZED)) {
          ShowWindow(data.hwnd, SW_SHOWMAXIMIZED);
        } else {
          ShowWindow(data.hwnd, SW_RESTORE);
        }
      }
      BringWindowToTop(data.hwnd);
      SetForegroundWindow(data.hwnd);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Devinorium", origin, size)) {
    CloseHandle(mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseHandle(mutex);
  return EXIT_SUCCESS;
}
