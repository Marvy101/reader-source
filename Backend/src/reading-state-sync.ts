type ReadingStateWithFileID = {
  fileId: string;
};

export function filterOwnedReadingStates<T extends ReadingStateWithFileID>(
  states: T[],
  ownedFileIDs: string[],
): T[] {
  const normalizedOwnedFileIDs = new Set(
    ownedFileIDs.map((fileID) => fileID.toLowerCase()),
  );

  return states.filter((state) =>
    normalizedOwnedFileIDs.has(state.fileId.toLowerCase()),
  );
}
