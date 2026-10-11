package com.yawasau.smbnotify;
import android.os.DeadObjectException;
public final class NotifyTest {
 public static void main(String[] args) throws Exception {
  if (args.length == 1) {
   android.graphics.Bitmap bmp = SmbNotifyUtil.buildSmbIconBitmap(96);
   if (android.graphics.Color.alpha(bmp.getPixel(0,0)) != 0) throw new AssertionError("background must be transparent");
   try (java.io.FileOutputStream out = new java.io.FileOutputStream(args[0])) {bmp.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
  }
  final int[] calls = {0};
  String a = SmbNotifyUtil.deliver(new SmbNotifyUtil.Backend() {
   public boolean available(){return false;}
   public void send(){throw new AssertionError("must not send");}
  });
  if (!a.contains("service_unavailable")) throw new AssertionError(a);
  String b = SmbNotifyUtil.deliver(new SmbNotifyUtil.Backend() {
   public boolean available(){return calls[0]++ == 0;}
   public void send(){throw new NullPointerException();}
  });
  if (!b.contains("service_disappeared")) throw new AssertionError(b);
  String c = SmbNotifyUtil.deliver(new SmbNotifyUtil.Backend() {
   public boolean available(){return true;}
   public void send() throws Exception {throw new DeadObjectException();}
  });
  if (!c.contains("service_disappeared")) throw new AssertionError(c);
  try {
   SmbNotifyUtil.deliver(new SmbNotifyUtil.Backend() {
    public boolean available(){return true;}
    public void send(){throw new NullPointerException("real defect");}
   });
   throw new AssertionError("unexpected defects must remain visible");
  } catch (NullPointerException expected) {}
  System.out.println("PASS unavailable, shutdown race, binder death, unexpected-error preservation");
 }
}
