import { useEffect, useState } from "react";

/** A minute clock for the exhausted band's "reset has passed" and the chip's
    limited state: read once on mount, then each minute. */
export function useNowMinute(): number {
  const [now, setNow] = useState(() => Date.now());
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- interval timer that ticks the clock each minute
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(id);
  }, []);
  return now;
}
