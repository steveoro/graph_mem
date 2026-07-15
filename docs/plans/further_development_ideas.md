# GraphMem main future development ideas:

## Management UI
- A quick report on duplicated observations, so that we can clean them easily with a single click. Duplicated observations have same source and target entities and same relation type. Investigate if the current implementation of the Garbage collector already handles this.
- Add a statistic report page given by GetGraphStatsTool

## Search UI
- Allow "smart search" that interprets numbers as entity IDs (rank 1), and generic text strings as entity names (rank 2), aliases (rank 3), or descriptions (rank 4).
