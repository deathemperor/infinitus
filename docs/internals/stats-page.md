# Stats page

Web and Electron Stats use `server.getStats` on each selected environment. The portable
scanner extends Usage's incremental transcript cache and uses the same live pricing and
custom overrides. Native `infinitusctl stats` remains a separate, compatible endpoint.

The travelling Stats model preserves session identities and sparse UTC minute buckets.
Clients select the newest copy of a session before folding totals; summing already-folded
summaries would count shared histories twice and cannot reconstruct a simultaneous peak.
Git object hashes and pull-request URLs deduplicate repository activity across clones.
All environments bucket in the requesting client's timezone and calendar window.

Missing provider metrics and inaccessible repository history are coverage gaps, not zero
activity. The native-only switch/limit history has no portable source. Streak history is
bounded to 800 days and a streak reaching that boundary is shown as a lower bound.
