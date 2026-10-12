#ifndef OMI_DIAGNOSTICS_H
#define OMI_DIAGNOSTICS_H

#include <stdint.h>

/* Values captured elsewhere and served by the Omi Diagnostics characteristic.
 * 0xFFFF / 0xFFFFFFFF mean "unknown" in the wire format. */
extern uint32_t diagnostics_reset_reas;          /* raw RESETREAS captured at boot */
extern uint16_t diagnostics_battery_mv;          /* last battery measurement */
extern uint16_t diagnostics_last_off_charger_mv; /* last measurement while not charging */
extern uint16_t diagnostics_charge_pin_edges;    /* bat_chg interrupts since boot */

/** Register the read-only Omi Diagnostics GATT service (19b10040/19b10041). */
void register_diagnostics_service(void);

#endif
