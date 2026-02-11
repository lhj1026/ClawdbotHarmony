/**
 * Native module for executing shell commands on HarmonyOS NEXT.
 * Uses popen() to run commands and capture stdout/stderr.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <napi/native_api.h>

// Max output size: 64KB
static constexpr size_t MAX_OUTPUT = 65536;

/**
 * execCmd(command: string, timeoutMs?: number): { stdout: string, stderr: string, exitCode: number }
 *
 * Runs a shell command via popen() and returns captured output.
 * stderr is captured by appending 2>&1 to the command.
 */
static napi_value ExecCmd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "execCmd requires a command string");
        return nullptr;
    }

    // Get command string
    size_t cmdLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &cmdLen);
    std::string command(cmdLen, '\0');
    napi_get_value_string_utf8(env, args[0], &command[0], cmdLen + 1, &cmdLen);

    // Append 2>&1 to capture stderr in stdout
    std::string fullCmd = command + " 2>&1";

    // Execute
    FILE *pipe = popen(fullCmd.c_str(), "r");
    if (!pipe) {
        // Return error result
        napi_value result;
        napi_create_object(env, &result);

        napi_value stdoutVal, stderrVal, exitCodeVal;
        napi_create_string_utf8(env, "", 0, &stdoutVal);
        napi_create_string_utf8(env, "popen() failed", 14, &stderrVal);
        napi_create_int32(env, -1, &exitCodeVal);

        napi_set_named_property(env, result, "stdout", stdoutVal);
        napi_set_named_property(env, result, "stderr", stderrVal);
        napi_set_named_property(env, result, "exitCode", exitCodeVal);
        return result;
    }

    // Read output
    std::string output;
    char buf[4096];
    while (fgets(buf, sizeof(buf), pipe) != nullptr) {
        output += buf;
        if (output.size() >= MAX_OUTPUT) {
            output = output.substr(0, MAX_OUTPUT);
            output += "\n...[truncated at 64KB]";
            break;
        }
    }

    int status = pclose(pipe);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    // Build result object
    napi_value result;
    napi_create_object(env, &result);

    napi_value stdoutVal, stderrVal, exitCodeVal;
    napi_create_string_utf8(env, output.c_str(), output.size(), &stdoutVal);
    napi_create_string_utf8(env, "", 0, &stderrVal);
    napi_create_int32(env, exitCode, &exitCodeVal);

    napi_set_named_property(env, result, "stdout", stdoutVal);
    napi_set_named_property(env, result, "stderr", stderrVal);
    napi_set_named_property(env, result, "exitCode", exitCodeVal);

    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"execCmd", nullptr, ExecCmd, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module execModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "exec",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterExecModule(void) {
    napi_module_register(&execModule);
}
