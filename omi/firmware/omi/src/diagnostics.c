/*
 * Omi Diagnostics characteristic, contract v1 as parsed by the app
 * (app/android/.../ble/FirmwareDiagnosticsParser.kt). Little-endian, 30 bytes:
 *
 *   0      u8   version (1)
 *   1..4   u32  reset cause flags (bit0 PIN, 1 SOFTWARE, 3 POR, 4 WATCHDOG,
 *               5 DEBUG, 7 LOW_POWER_WAKE, 8 CPU_LOCKUP)
 *   5..8   u32  uptime seconds
 *   9..10  u16  battery mV (0xFFFF unknown)
 *   11     u8   charging (0/1, 0xFF unknown)
 *   12     u8   reserved
 *   13..24 u32  mic overrun / BLE TX drop / storage error counts (unknown)
 *   25..26 u16  last battery mV measured off the charger
 *   27..28 u16  charge-pin edges since boot (a flaky contact shows up here)
 *   29     u8   soc_frozen (0xFF unknown)
 */
#include "diagnostics.h"

#include <hal/nrf_reset.h>
#include <string.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/byteorder.h>

#define DIAGNOSTICS_VERSION 1
#define DIAGNOSTICS_LEN 30

uint32_t diagnostics_reset_reas;
uint16_t diagnostics_battery_mv = 0xFFFF;
uint16_t diagnostics_last_off_charger_mv = 0xFFFF;
uint16_t diagnostics_charge_pin_edges;

extern bool is_charging;

static uint32_t reset_flags(uint32_t reas)
{
    uint32_t flags = 0;

    if (reas == 0) {
        return BIT(3); /* power-on reset (includes brown-out on nRF5340) */
    }
    if (reas & NRF_RESET_RESETREAS_RESETPIN_MASK) {
        flags |= BIT(0);
    }
    if (reas & NRF_RESET_RESETREAS_SREQ_MASK) {
        flags |= BIT(1);
    }
    if (reas & (NRF_RESET_RESETREAS_DOG0_MASK | NRF_RESET_RESETREAS_DOG1_MASK)) {
        flags |= BIT(4);
    }
    if (reas & NRF_RESET_RESETREAS_DIF_MASK) {
        flags |= BIT(5);
    }
    if (reas & NRF_RESET_RESETREAS_OFF_MASK) {
        flags |= BIT(7); /* woke from System OFF (button, or charger with the wake patch) */
    }
    if (reas & NRF_RESET_RESETREAS_LOCKUP_MASK) {
        flags |= BIT(8);
    }
    return flags;
}

static ssize_t
diagnostics_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint8_t value[DIAGNOSTICS_LEN];

    memset(value, 0xFF, sizeof(value));
    value[0] = DIAGNOSTICS_VERSION;
    sys_put_le32(reset_flags(diagnostics_reset_reas), &value[1]);
    sys_put_le32((uint32_t) (k_uptime_get() / 1000), &value[5]);
    sys_put_le16(diagnostics_battery_mv, &value[9]);
    value[11] = is_charging ? 1 : 0;
    value[12] = 0;
    sys_put_le16(diagnostics_last_off_charger_mv, &value[25]);
    sys_put_le16(diagnostics_charge_pin_edges, &value[27]);

    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}

static struct bt_uuid_128 diagnostics_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10040, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diagnostics_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10041, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static struct bt_gatt_attr diagnostics_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&diagnostics_service_uuid),
    BT_GATT_CHARACTERISTIC(&diagnostics_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           diagnostics_read,
                           NULL,
                           NULL),
};

static struct bt_gatt_service diagnostics_service = BT_GATT_SERVICE(diagnostics_service_attr);

void register_diagnostics_service(void)
{
    bt_gatt_service_register(&diagnostics_service);
}
