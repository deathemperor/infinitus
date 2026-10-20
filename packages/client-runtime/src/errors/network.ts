<<<<<<< HEAD
import { CONNECT_NAME } from "@infinitus/shared/productName";
// A failed request cannot distinguish filtering from an outage. Keep this a
// possible cause, and suggest a way to check without changing server settings.
export const NETWORK_BLOCKING_HINT = `Your DNS or firewall may be blocking ${CONNECT_NAME}. Try another network, such as a phone hotspot.`;
=======
export const NETWORK_BLOCKING_HINT =
  "Your DNS or firewall may be blocking T3 Connect. Try another network, such as a different Wi-Fi or mobile data.";

/** For a host that stopped answering on an open connection, so the network path was already working. */
export const UNRESPONSIVE_HOST_HINT = "It may be overloaded, asleep, or off the network.";
>>>>>>> upstream-sync-774c6c195-upstream-renamed
