package app.alextran.immich.cloudmedia;

import android.os.Bundle;

// Fixed, narrowly scoped admission operations. Never accepts a command/path/token.
interface ICloudAdmission {
  Bundle inspect() = 0;
  Bundle admit(in Bundle expected) = 1;
  Bundle undo(in Bundle journal) = 2;
  void cancel() = 3;
  void destroy() = 16777114;
}
