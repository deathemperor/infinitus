import { CONNECT_NAME } from "@t3tools/shared/productName";
// A failed request cannot distinguish filtering from an outage. Keep this a
// possible cause, and suggest a way to check without changing server settings.
export const NETWORK_BLOCKING_HINT = `Your DNS or firewall may be blocking ${CONNECT_NAME}. Try another network, such as a phone hotspot.`;
