// CxxBridge.mm — intentionally empty Objective-C++ source file.
//
// TensorFlowLiteC.xcframework ships C++ symbols (std::string, std::mutex, …)
// that require libc++ to be linked into the final binary. A pure Swift app
// target does not automatically pull in libc++, which produces hundreds of
// "Undefined symbol: std::__1::basic_string<...>" link errors.
//
// Having at least one .mm file in the target makes Xcode link libc++
// automatically. This file has no declarations — its mere presence is the
// whole fix. Do not add code here; keep it empty so it stays obviously
// intentional.
