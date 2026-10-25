/*
 * ESP32-S3 USB HID "keyboard" jog pendant for a TechnoCNC LC-series router,
 * sent over the native USB (OTG) port.
 *
 * Key assignments (as given):
 *   +X = Right arrow   -X = Left arrow
 *   +Y = Up arrow       -Y = Down arrow
 *   +Z = "+"            -Z = "-"
 *   Step = F8           Continuous = F9
 *   Abort = Escape       Enable = not sent to the host at all (local only)
 *
 * The "+"/"-" keys are sent as the standard top-row "+"/"-"/"=" keys
 * (Shift+"=" for "+", plain "-" for "-"); either that or the numpad +/-
 * keys work identically at the host, so the top-row ones are used here.
 *
 * Switches (10 Cherry MX momentary contacts + 2 status LEDs):
 *
 *   +X, -X, +Y, -Y, +Z, -Z   Axis jog switches, typematic-style:
 *                              - A tap (press then quick release) sends a
 *                                single key press+release -- one character.
 *                              - Holding past JOG_REPEAT_DELAY_MS sends a
 *                                steady stream of key press+release pulses,
 *                                one every JOG_REPEAT_INTERVAL_MS, for as
 *                                long as the switch stays held.
 *                              - Releasing immediately stops the stream;
 *                                no further characters are sent.
 *                            Always active (no enable gating).
 *
 *   Step, Continuous         Mutually-exclusive jog-mode selector. Pressing
 *                            one sends a single key tap (press+release) and
 *                            lights that switch's LED; the other LED turns
 *                            off. Always active (no enable gating).
 *
 *   Enable                   Hold for ENABLE_HOLD_MS (3000 ms) continuously
 *                            to toggle a local armed/disarmed flag. Nothing
 *                            is sent to the host for this switch -- it only
 *                            affects this firmware's own state (used here
 *                            to track what Abort force-resets). Releasing
 *                            before 3 s cancels the attempt.
 *
 *   Abort                    Acts like an e-stop: a single tap sends its
 *                            key immediately on press, with no hold and no
 *                            delay beyond normal contact debounce, and
 *                            always forces the local armed flag to false.
 *
 * All switches wire one leg to their GPIO and the other to GND, using the
 * internal pull-up (no external resistor needed). The two mode LEDs are
 * plain GPIO outputs; wire each through a current-limiting resistor
 * (~330 ohm) to an LED to GND.
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_log.h"

#include "tinyusb.h"
#include "tinyusb_default_config.h"   /* TINYUSB_DEFAULT_CONFIG() -- esp_tinyusb 2.x/3.x */
#include "class/hid/hid_device.h"

static const char *TAG = "usb_jog";

/* ------------------------------------------------------------------ */
/* Timing                                                              */
/* ------------------------------------------------------------------ */

#define POLL_MS                  5     /* switch scan period                    */
#define DEBOUNCE_MS              20    /* stable time before accepting a change */
#define ENABLE_HOLD_MS           3000  /* continuous hold time to toggle enable */

#define TAP_DOWN_MS              15    /* how long a key is held down for one tap */
#define JOG_REPEAT_DELAY_MS      400   /* hold time before an axis switch starts repeating */
#define JOG_REPEAT_INTERVAL_MS   60    /* time between repeat taps while an axis switch is held */

/* ------------------------------------------------------------------ */
/* Switch / LED pin configuration -- EDIT TO MATCH YOUR WIRING         */
/* ------------------------------------------------------------------ */

/*
 * GPIO 4-9 and 15-18 are free on the Freenove ESP32-S3 boards. Avoid GPIO
 * 19/20 (native USB D-/D+), 0/3/45/46 (strapping), 26-37 (flash/PSRAM) and
 * 43/44 (UART0 console). Check your board's pinout diagram if you change
 * any of these.
 */

#define NUM_AXES   6
#define NUM_MODES  2

typedef struct {
    gpio_num_t  pin;       /* GPIO, switch to GND, active low */
    uint8_t     modifier;  /* KEYBOARD_MODIFIER_* bitmask (0 = none) */
    uint8_t     keycode;   /* HID_KEY_* usage code */
    const char *name;      /* for logging */
} axis_cfg_t;

static const axis_cfg_t axis_switches[NUM_AXES] = {
    { GPIO_NUM_4,  0,                          HID_KEY_ARROW_RIGHT, "+X" },
    { GPIO_NUM_5,  0,                          HID_KEY_ARROW_LEFT,  "-X" },
    { GPIO_NUM_6,  0,                          HID_KEY_ARROW_UP,    "+Y" },
    { GPIO_NUM_7,  0,                          HID_KEY_ARROW_DOWN,  "-Y" },
    /* "+" sent as Shift+"=" (top-row). Numpad HID_KEY_KEYPAD_ADD works the
     * same at the host if you'd rather wire this as a numpad-style key. */
    { GPIO_NUM_15, KEYBOARD_MODIFIER_LEFTSHIFT, HID_KEY_EQUAL,       "+Z" },
    /* "-" sent as the top-row minus key. Numpad HID_KEY_KEYPAD_SUBTRACT
     * works the same at the host if you'd rather wire this as numpad-style. */
    { GPIO_NUM_16, 0,                          HID_KEY_MINUS,       "-Z" },
};

typedef struct {
    gpio_num_t  pin;       /* GPIO, switch to GND, active low */
    uint8_t     modifier;  /* KEYBOARD_MODIFIER_* bitmask (0 = none) */
    uint8_t     keycode;   /* HID_KEY_* usage code */
    gpio_num_t  led_pin;   /* lit while this mode is selected */
    const char *name;      /* for logging */
} mode_cfg_t;

static const mode_cfg_t mode_switches[NUM_MODES] = {
    { GPIO_NUM_17, 0, HID_KEY_F8, GPIO_NUM_10, "Step"       },
    { GPIO_NUM_18, 0, HID_KEY_F9, GPIO_NUM_11, "Continuous" },
};


/* Enable is local only: it toggles an internal armed flag but no key is
 * ever sent to the host for it -- see the enable handling in app_main(). */
#define ENABLE_PIN      GPIO_NUM_8

#define ABORT_PIN       GPIO_NUM_9
#define ABORT_MODIFIER  0
#define ABORT_KEYCODE   HID_KEY_ESCAPE

/* ------------------------------------------------------------------ */
/* USB descriptors                                                     */
/* ------------------------------------------------------------------ */

static const uint8_t hid_report_descriptor[] = {
    TUD_HID_REPORT_DESC_KEYBOARD()   /* no report ID, standard 8-byte boot report */
};

static const char *hid_string_descriptor[] = {
    (char[]){ 0x09, 0x04 },     /* 0: language = English (US) */
    "ESP32-S3",                 /* 1: manufacturer */
    "CNC Jog Pendant",          /* 2: product */
    "123456",                   /* 3: serial */
    "CNC Jog Pendant HID",      /* 4: HID interface */
};

#define TUSB_DESC_TOTAL_LEN (TUD_CONFIG_DESC_LEN + CFG_TUD_HID * TUD_HID_DESC_LEN)

static const uint8_t hid_configuration_descriptor[] = {
    /* config number, interface count, string index, total length, attributes, power (mA) */
    TUD_CONFIG_DESCRIPTOR(1, 1, 0, TUSB_DESC_TOTAL_LEN,
                          TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),

    /* interface, string index, boot protocol, report desc len, EP in addr, size, interval (ms) */
    TUD_HID_DESCRIPTOR(0, 4, false, sizeof(hid_report_descriptor), 0x81, 16, 10),
};

/* TinyUSB HID callbacks (required) */
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance)
{
    (void)instance;
    return hid_report_descriptor;
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
                               hid_report_type_t report_type,
                               uint8_t *buffer, uint16_t reqlen)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)reqlen;
    return 0;
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type,
                           uint8_t const *buffer, uint16_t bufsize)
{
    /* Host -> device output report (e.g. Caps Lock LED). Not used. */
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)bufsize;
}

/* ------------------------------------------------------------------ */
/* Sending reports                                                     */
/* ------------------------------------------------------------------ */

/* Wait briefly for the HID endpoint to be free, then send a keyboard report. */
static void send_report(uint8_t modifier, const uint8_t keys[6])
{
    if (!tud_mounted()) {
        ESP_LOGW(TAG, "USB not mounted by host, dropping report");
        return;
    }

    if (tud_suspended()) {
        tud_remote_wakeup();              /* wake a sleeping host */
        vTaskDelay(pdMS_TO_TICKS(50));
    }

    for (int i = 0; i < 50 && !tud_hid_ready(); i++) {
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    if (!tud_hid_ready()) {
        ESP_LOGW(TAG, "HID endpoint busy, dropping report");
        return;
    }

    tud_hid_keyboard_report(0, modifier, keys);
}

/*
 * Send a single discrete key tap: press, hold briefly, release. Used for
 * every switch in this design -- axis switches call this once per
 * character (immediately on press, then again each repeat interval while
 * held); Step/Continuous/Abort call it once per press.
 */
static void send_tap(uint8_t modifier, uint8_t keycode)
{
    uint8_t keys[6] = { keycode, 0, 0, 0, 0, 0 };
    send_report(modifier, keys);
    vTaskDelay(pdMS_TO_TICKS(TAP_DOWN_MS));

    uint8_t none[6] = { 0 };
    send_report(0, none);
}

/* ------------------------------------------------------------------ */
/* GPIO setup                                                          */
/* ------------------------------------------------------------------ */

static void switches_init(void)
{
    uint64_t input_mask = (1ULL << ENABLE_PIN) | (1ULL << ABORT_PIN);
    for (int i = 0; i < NUM_AXES; i++) {
        input_mask |= 1ULL << axis_switches[i].pin;
    }
    for (int i = 0; i < NUM_MODES; i++) {
        input_mask |= 1ULL << mode_switches[i].pin;
    }

    gpio_config_t in_cfg = {
        .pin_bit_mask = input_mask,
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&in_cfg));

    uint64_t led_mask = 0;
    for (int i = 0; i < NUM_MODES; i++) {
        led_mask |= 1ULL << mode_switches[i].led_pin;
    }

    gpio_config_t out_cfg = {
        .pin_bit_mask = led_mask,
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&out_cfg));

    for (int i = 0; i < NUM_MODES; i++) {
        gpio_set_level(mode_switches[i].led_pin, 0);   /* both off until a mode is picked */
    }
}

static void set_mode_leds(int selected_mode)
{
    for (int i = 0; i < NUM_MODES; i++) {
        gpio_set_level(mode_switches[i].led_pin, (i == selected_mode) ? 1 : 0);
    }
}

/* ------------------------------------------------------------------ */
/* Application                                                         */
/* ------------------------------------------------------------------ */

void app_main(void)
{
    switches_init();

    ESP_LOGI(TAG, "Starting USB HID jog pendant");

    /* esp_tinyusb 2.x/3.x API: start from the library's own defaults, then
     * override only the descriptors we actually customize. The device
     * descriptor is left at its default (NULL), which uses the
     * manufacturer/product/serial strings from Kconfig combined with our
     * own string array below for anything beyond those (our HID interface
     * name at string index 4). */
    tinyusb_config_t tusb_cfg = TINYUSB_DEFAULT_CONFIG();
    tusb_cfg.descriptor.string            = hid_string_descriptor;
    tusb_cfg.descriptor.full_speed_config = hid_configuration_descriptor;
#if (TUD_OPT_HIGH_SPEED)
    tusb_cfg.descriptor.high_speed_config = hid_configuration_descriptor;
#endif
    ESP_ERROR_CHECK(tinyusb_driver_install(&tusb_cfg));

    const uint8_t needed = DEBOUNCE_MS / POLL_MS;

    /* Axis switches: debounced hold state drives a tap-then-repeat stream. */
    bool       axis_pressed[NUM_AXES]    = { false };
    uint8_t    axis_counter[NUM_AXES]    = { 0 };
    TickType_t axis_next_tap[NUM_AXES]   = { 0 };

    /* Mode switches: debounced edge -> one-shot tap + LED update. */
    bool    mode_stable[NUM_MODES]  = { false };
    uint8_t mode_counter[NUM_MODES] = { 0 };
    int     current_mode            = -1;   /* -1 = none selected yet */

    /* Enable switch: debounce, then a continuous 3 s hold toggles "armed". */
    bool       enable_stable  = false;
    uint8_t    enable_counter = 0;
    bool       armed          = false;
    bool       hold_consumed  = false;
    TickType_t press_start    = 0;

    /* Abort switch: plain debounced edge, no hold required. */
    bool    abort_stable  = false;
    uint8_t abort_counter = 0;

    while (1) {
        TickType_t now = xTaskGetTickCount();

        /* --- axis switches: tap on press, then a repeating stream while held --- */
        for (int i = 0; i < NUM_AXES; i++) {
            bool raw = (gpio_get_level(axis_switches[i].pin) == 0);   /* active low */

            if (raw == axis_pressed[i]) {
                axis_counter[i] = 0;
            } else if (++axis_counter[i] >= needed) {
                axis_pressed[i] = raw;
                axis_counter[i] = 0;

                if (raw) {
                    /* debounced press edge: send the first character right away */
                    ESP_LOGI(TAG, "%s pressed", axis_switches[i].name);
                    send_tap(axis_switches[i].modifier, axis_switches[i].keycode);
                    axis_next_tap[i] = now + pdMS_TO_TICKS(JOG_REPEAT_DELAY_MS);
                } else {
                    ESP_LOGI(TAG, "%s released", axis_switches[i].name);
                }
            }

            if (axis_pressed[i] && now >= axis_next_tap[i]) {
                /* still held and the next repeat is due: send another character */
                send_tap(axis_switches[i].modifier, axis_switches[i].keycode);
                axis_next_tap[i] = now + pdMS_TO_TICKS(JOG_REPEAT_INTERVAL_MS);
                now = xTaskGetTickCount();   /* sending a tap takes real time; refresh */
            }
        }

        /* --- mode switches (Step / Continuous) --- */
        for (int i = 0; i < NUM_MODES; i++) {
            bool raw = (gpio_get_level(mode_switches[i].pin) == 0);   /* active low */

            if (raw == mode_stable[i]) {
                mode_counter[i] = 0;
            } else if (++mode_counter[i] >= needed) {
                mode_stable[i]  = raw;
                mode_counter[i] = 0;

                if (raw) {   /* debounced press edge */
                    current_mode = i;
                    set_mode_leds(current_mode);
                    ESP_LOGI(TAG, "Mode -> %s", mode_switches[i].name);
                    send_tap(mode_switches[i].modifier, mode_switches[i].keycode);
                }
            }
        }

        /* --- enable switch: debounce, then require a 3 s continuous hold --- */
        bool enable_raw = (gpio_get_level(ENABLE_PIN) == 0);   /* active low */

        if (enable_raw == enable_stable) {
            enable_counter = 0;
        } else if (++enable_counter >= needed) {
            enable_stable  = enable_raw;
            enable_counter = 0;

            if (enable_stable) {
                press_start   = xTaskGetTickCount();
                hold_consumed = false;
            } else if (!hold_consumed) {
                ESP_LOGI(TAG, "Enable switch released early, hold attempt cancelled");
            }
        }

        if (enable_stable && !hold_consumed) {
            TickType_t held_ms = (xTaskGetTickCount() - press_start) * portTICK_PERIOD_MS;
            if (held_ms >= ENABLE_HOLD_MS) {
                armed         = !armed;
                hold_consumed = true;
                ESP_LOGI(TAG, "Enable switch held 3 s: %s (local only, nothing sent to host)",
                         armed ? "ARMED" : "DISARMED");
                /* No send_tap() here: per spec, Enable is never sent to the controller. */
            }
        }

        /* --- abort switch: immediate tap, always forces disarmed --- */
        bool abort_raw = (gpio_get_level(ABORT_PIN) == 0);   /* active low */

        if (abort_raw == abort_stable) {
            abort_counter = 0;
        } else if (++abort_counter >= needed) {
            abort_stable  = abort_raw;
            abort_counter = 0;

            if (abort_raw) {   /* debounced press edge: act immediately, no delay */
                armed = false;
                ESP_LOGW(TAG, "ABORT pressed -- forcing DISARMED");
                send_tap(ABORT_MODIFIER, ABORT_KEYCODE);
            }
        }

        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
    }
}
