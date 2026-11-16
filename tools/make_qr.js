// make_qr.js —— 用 macOS 内置 CoreImage 生成二维码 PNG（JXA，无第三方依赖）
// 用法：osascript -l JavaScript make_qr.js "<文本>" "<输出png路径>"
ObjC.import('Foundation');
ObjC.import('CoreImage');
ObjC.import('AppKit');

function run(argv) {
  const text = argv[0];
  const out = argv[1];
  const data = $(text).dataUsingEncoding($.NSUTF8StringEncoding);

  const filter = $.CIFilter.filterWithName('CIQRCodeGenerator');
  filter.setValueForKey(data, 'inputMessage');
  filter.setValueForKey('M', 'inputCorrectionLevel');

  let img = filter.outputImage;
  if (!img) return 'ERROR:no-output-image';
  img = img.imageByApplyingTransform($.CGAffineTransformMakeScale(14, 14));

  const ctx = $.CIContext.context;
  const cg = ctx.createCGImageFromRect(img, img.extent);
  const rep = $.NSBitmapImageRep.alloc.initWithCGImage(cg);
  const png = rep.representationUsingTypeProperties($.NSPNGFileType, $({}));

  return png.writeToFileAtomically(out, true) ? 'OK' : 'ERROR:write-failed';
}
