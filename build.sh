#!/bin/zsh
# 한글스캔 PDF.app 빌드 스크립트
set -e
cd "$(dirname "$0")"
APP="build/한글스캔 PDF.app"
echo "▶ 릴리스 빌드 중…"
swift build -c release
echo "▶ 앱 번들 만드는 중…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HangulScan "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# 아이콘: Resources 폴더에 이미지(png/jpg/heic/webp)가 있으면 그것을 사용
icons=(Resources/*.(png|jpg|jpeg|heic|webp|PNG|JPG|JPEG)(N))
ICON_SRC=${icons[1]}
# 사용자 이미지가 있으면 매번 새로 만듦 (파일 수정 시각과 무관하게 확실히 반영)
if [ ! -f build/AppIcon.icns ] || [ -n "$ICON_SRC" ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset ${ICON_SRC:+"$ICON_SRC"}
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
# PDF 문서 아이콘 (이 앱이 PDF 기본 앱일 때 Finder의 PDF 파일 아이콘)
if [ ! -f build/PDFDocument.icns ] || [ -n "$ICON_SRC" ] || [ scripts/make_doc_icon.swift -nt build/PDFDocument.icns ]; then
  rm -rf build/PDFDocument.iconset && mkdir -p build/PDFDocument.iconset
  swift scripts/make_doc_icon.swift build/PDFDocument.iconset ${ICON_SRC:+"$ICON_SRC"}
  iconutil -c icns build/PDFDocument.iconset -o build/PDFDocument.icns
fi
cp build/PDFDocument.icns "$APP/Contents/Resources/"
# 문서 폴더 등에서 붙는 확장 속성(Finder 정보 등)은 서명을 막으므로 제거
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "✅ 완료: $APP"
