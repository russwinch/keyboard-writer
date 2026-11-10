/*
 * Lets the Keyboard Writer app put this board into its bootloader over USB,
 * so there is no need to double-tap reset.
 *
 * The board shows up as a USB serial port (dts/keyboard_writer.dtsi).
 * When something opens the port it says which device it is, e.g.
 * "keyboard-writer waterfowl_left"; when the port is set to 1200 baud it reboots into the
 * bootloader, the same signal Arduino boards use. Nothing runs while the
 * board is not on USB power.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/init.h>
#include <zephyr/retention/bootmode.h>
#include <zephyr/sys/reboot.h>

#include <zmk/event_manager.h>
#include <zmk/events/usb_conn_state_changed.h>
#include <zmk/usb.h>

#define POLL_MS 100
#define BOOTLOADER_BAUD 1200

// KEYBOARD_WRITER_DEVICE is the build's first shield (CMakeLists.txt)
static const char greeting[] = "keyboard-writer " KEYBOARD_WRITER_DEVICE "\n";

static const struct device *port = DEVICE_DT_GET(DT_NODELABEL(keyboard_writer_port));
static bool greeted;

static void poll_cb(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(poll_work, poll_cb);

static void poll_cb(struct k_work *work) {
    if (!zmk_usb_is_powered() || !device_is_ready(port)) {
        greeted = false;
        return; // the listener below starts it again
    }

    uint32_t baud = 0, open = 0;
    uart_line_ctrl_get(port, UART_LINE_CTRL_BAUD_RATE, &baud);
    uart_line_ctrl_get(port, UART_LINE_CTRL_DTR, &open);

    if (baud == BOOTLOADER_BAUD && bootmode_set(BOOT_MODE_TYPE_BOOTLOADER) == 0) {
        sys_reboot(SYS_REBOOT_WARM);
    }
    if (open && !greeted) {
        for (const char *c = greeting; *c; c++) {
            uart_poll_out(port, *c);
        }
    }
    greeted = open;

    k_work_reschedule(&poll_work, K_MSEC(POLL_MS));
}

static int keyboard_writer_listener(const zmk_event_t *eh) {
    k_work_reschedule(&poll_work, K_NO_WAIT);
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(keyboard_writer, keyboard_writer_listener);
ZMK_SUBSCRIPTION(keyboard_writer, zmk_usb_conn_state_changed);

static int keyboard_writer_init(void) {
    k_work_reschedule(&poll_work, K_SECONDS(1));
    return 0;
}

SYS_INIT(keyboard_writer_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
