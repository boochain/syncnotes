import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/ui/block_card.dart';

void main() {
  test('card body does not repeat the title', () {
    expect(previewWithoutTitle('买牛奶', '买牛奶'), '');
    expect(previewWithoutTitle('周会', '周会\n讨论发布计划'), '讨论发布计划');
    expect(previewWithoutTitle('这是一段很长的消息…', '这是一段很长的消息，后面还有内容'), '，后面还有内容');
    // 只是前缀相同的不同词不去掉
    expect(previewWithoutTitle('会议', '会议纪要'), '会议纪要');
    expect(previewWithoutTitle('', '正文'), '正文');
  });
}
