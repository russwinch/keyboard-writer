# Which device this build is for, told to the app over USB: the first shield,
# e.g. "waterfowl_left nice_view_adapter nice_view" -> waterfowl_left.
if(CONFIG_KEYBOARD_WRITER)
  string(REGEX MATCH "^[^ ;]+" keyboard_writer_device "${SHIELD}")
  target_sources(app PRIVATE src/usb_trigger.c)
  target_compile_definitions(app PRIVATE KEYBOARD_WRITER_DEVICE="${keyboard_writer_device}")
endif()
