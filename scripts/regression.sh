#!/bin/zsh
# 자동 회귀 시험: ./scripts/regression.sh  (릴리스 빌드 후 실행)
cd "$(dirname "$0")/.."
B=.build/release/HangulScan
T=$(mktemp -d /tmp/hangulscan_test.XXXX)
pass=0; fail=0
check() { if eval "$2"; then echo "✅ $1"; pass=$((pass+1)); else echo "❌ $1"; fail=$((fail+1)); fi }
chars() { $B --selftest "$@" 2>&1 | grep "결과 PDF" | sed -E 's/.*글자 ([0-9]+)자.*/\1/' }

echo "▶ 테스트 이미지 만들기 ($T)"
swift scripts/make_test_assets.swift $T >/dev/null 2>&1

echo "▶ 1. 사진 보정 + 한국어 OCR (기울기·사진·90°·-90°·180°)"
for f in skew35 photo_m7 rot90 rotm90 rot180; do
  n=$(chars $T/$f.png $T/o_$f.pdf); check "$f: 글자 ${n}자 (기대 ≥200)" "[ \"${n:-0}\" -ge 200 ]"
done

echo "▶ 2. 책 모드로 일반 문서 (분리되면 안 됨)"
r=$($B --selftest $T/skew35.png $T/o_book.pdf --book 2>&1 | grep "결과 PDF")
check "책 모드 일반 문서: $r" "echo '$r' | grep -q '1쪽, 추출 가능한 글자 2[0-9][0-9]자'"

echo "▶ 3. 스캔 PDF 12쪽 OCR"
r=$($B --selftest $T/a4_12.pdf $T/o_a4.pdf 2>&1 | grep "결과 PDF")
check "A4 12쪽: $r" "echo '$r' | grep -q '12쪽, 추출 가능한 글자 24[0-9][0-9]자'"
r=$($B --selftest $T/o_a4.pdf $T/o_a4_again.pdf 2>&1 | grep -c "이미 텍스트 있음")
check "이미 OCR한 쪽 건너뛰기 (${r}/12)" "[ $r -eq 12 ]"
r=$($B --probe $T/o_a4.pdf 2>&1)
check "글자층 판별: OCR 글자층" "echo '$r' | grep -q 'OCR 글자층'"
r=$($B --probe $T/a4_12.pdf 2>&1)
check "글자층 판별: 글자 없음" "echo '$r' | grep -q '글자 없음'"

echo "▶ 4. 표·문단 인식"
r=$($B --structure $T/table.png 2>&1)
check "표 5행 인식" "[ \$(echo '$r' | grep -c $'\t') -ge 5 ]"
check "표 내용 '성경 퀴즈' '본당 2층'" "echo '$r' | grep -q $'성경 퀴즈\t본당 2층'"

echo "▶ 5. 교정 반영"
r=$($B --correcttest $T/o_a4.pdf $T/o_corr.pdf 2>&1)
check "교정 글자 검색 1건·예전 글자 0건" "echo \"\$r\" | grep -q '검색: 1건, 예전 첫 줄 검색: 0건'"

echo "▶ 6. 용량 줄이기 (검색 글자 유지)"
r=$($B --compress $T/o_a4.pdf $T 2>&1)
check "세 단계 모두 검색 12건" "[ \$(echo '$r' | grep -c '검색 12건') -eq 3 ]"

echo "▶ 7. 쪽 크기 통일"
mkdir -p $T/mix; cp $T/skew35.png $T/photo_m7.png $T/rot90.png $T/table.png $T/mix/
$B --selftest $T/mix $T/o_mix.pdf >/dev/null 2>&1
n=$(swift -e 'import PDFKit; let d = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!; print(Set((0..<d.pageCount).map { let b = d.page(at: $0)!.bounds(for: .mediaBox); return "\(Int(min(b.width,b.height)))x\(Int(max(b.width,b.height)))" }).count)' $T/o_mix.pdf 2>/dev/null)
check "4장 모두 같은 크기 (크기 종류 ${n}개)" "[ \"$n\" = 1 ]"

echo "▶ 8. 폴더 자동 OCR"
mkdir -p $T/watch; cp $T/skew35.png $T/watch/사진.png; cp $T/a4_12.pdf "$T/watch/스캔 문서.pdf"; echo x > $T/watch/깨진.pdf
r=$($B --watchtest $T/watch 40 2>&1)
check "완료 2·실패 1 ($(echo $r | head -1))" "echo '$r' | grep -q '완료 2, 실패 1'"
check "결과·원본 폴더 정리" "[ -f '$T/watch/OCR 완료/사진.pdf' ] && [ -f '$T/watch/처리한 원본/사진.png' ] && [ -f '$T/watch/OCR 실패/깨진.pdf' ]"

echo ""
echo "결과: 통과 $pass, 실패 $fail"
rm -rf $T
[ $fail -eq 0 ]
