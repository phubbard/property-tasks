# Changelog

## [Unreleased]

- Camera-first capture on iPhone and iPad: a Capture button on the Space view opens the
  camera, then title, place (last used, recents, search, or the Inbox created on first use)
  and a priority chip; Done creates the task and attaches every photo. The item page gains a
  Take photo button using the same camera.
- Offline photos: attachment events apply locally at once; originals and derivatives are
  staged on device and uploaded from a persisted queue that retries on the next refresh.
  Thumbnails show the local derivative with an upload badge until the bytes are accepted.
- Capture sidecar records GPS, compass heading, device attitude and camera intrinsics at the
  shutter, with EXIF filling in for library photos. Location and motion usage strings added.
- First app skeleton: Spaces list, tree and list views with filters, node page with status,
  priority, labels, children, attachments and history; photo attach via the photo picker;
  events sync with the Worker and are cached on device.
