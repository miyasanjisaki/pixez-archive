import 'package:dio/dio.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/models/bookmark_detail.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/utils/illust_bookmark_tags.dart';

part 'tag_for_illust_store.g.dart';

class TagForIllustStore = _TagForIllustStoreBase with _$TagForIllustStore;

abstract class _TagForIllustStoreBase with Store {
  @observable
  String? errorMessage;
  final int id;

  _TagForIllustStoreBase(this.id);

  @observable
  bool isBookmarked = false;

  @observable
  String restrict = "public";

  ObservableList<bool> checkList = ObservableList();

  ObservableList<TagsR> tags = ObservableList();

  List<String> get selectedTagNames {
    final selected = <String>[];
    for (var index = 0; index < tags.length; index++) {
      if (index < checkList.length && checkList[index]) {
        selected.add(tags[index].name);
      }
    }
    return normalizeIllustBookmarkTags(selected);
  }

  @action
  setRestrict(bool value) {
    restrict = value ? "public" : "private";
  }

  @action
  insert(TagsR tagsR) {
    final name = tagsR.name.trim();
    if (name.isEmpty) return;
    final existingIndex = tags.indexWhere((tag) => tag.name.trim() == name);
    if (existingIndex >= 0) {
      check(existingIndex, true);
      return;
    }
    tags.insert(0, TagsR(name: name, isRegistered: true));
    checkList.insert(0, true);
  }

  @action
  check(int index, bool value) {
    tags[index].isRegistered = value;
    checkList[index] = value;
  }

  @action
  fetch() async {
    try {
      Response response = await apiClient.getIllustBookmarkDetail(id);
      BookMarkDetailResponse bookMarkDetailResponse =
          BookMarkDetailResponse.fromJson(response.data);
      checkList.clear();
      tags.clear();
      tags.addAll(bookMarkDetailResponse.bookmarkDetail.tags);
      for (var i in tags) checkList.add(i.isRegistered); //这也太捉急了
      isBookmarked = bookMarkDetailResponse.bookmarkDetail.isBookmarked;
      bookMarkDetailResponse.bookmarkDetail.restrict;
      restrict = bookMarkDetailResponse.bookmarkDetail.restrict;
    } catch (e) {
      errorMessage = "" + e.toString();
    }
  }

  @action
  checkAll() {
    bool isAllChecked = checkList.every((element) => element);
    for (int i = 0; i < checkList.length; i++) {
      check(i, !isAllChecked);
    }
  }
}
