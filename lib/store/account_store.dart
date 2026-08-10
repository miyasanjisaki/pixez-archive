/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:async';

import 'package:mobx/mobx.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/models/account.dart';

part 'account_store.g.dart';

class AccountStore = _AccountStoreBase with _$AccountStore;

abstract class _AccountStoreBase with Store {
  AccountProvider accountProvider = new AccountProvider();
  @observable
  AccountPersist? now;
  @observable
  int index = 0;
  @observable
  bool feching = false;

  ObservableList<AccountPersist> accounts = ObservableList();
  int _generation = 0;
  bool _deletingAll = false;
  Future<void> _operationTail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @action
  select(int selectedIndex) async {
    if (selectedIndex < 0 || selectedIndex >= accounts.length) return;
    final selected = accounts[selectedIndex];
    final generation = ++_generation;
    await Prefer.setInt('account_select_num', selectedIndex);
    if (generation != _generation || _deletingAll) return;
    now = selected;
    index = selectedIndex;
  }

  @action
  deleteAll() async {
    final generation = ++_generation;
    _deletingAll = true;
    accounts.clear();
    index = 0;
    now = null;
    try {
      await _serialize(() async {
        await accountProvider.open();
        await accountProvider.deleteAll();
      });
    } finally {
      if (generation == _generation) _deletingAll = false;
    }
  }

  @action
  Future<bool> updateSingle(AccountPersist accountPersist) async {
    final generation = _generation;
    final currentId = now?.id;
    if (_deletingAll || currentId == null || currentId != accountPersist.id) {
      return false;
    }
    return _serialize(() async {
      if (_deletingAll ||
          generation != _generation ||
          now?.id != accountPersist.id) {
        return false;
      }
      await accountProvider.open();
      if (_deletingAll ||
          generation != _generation ||
          now?.id != accountPersist.id) {
        return false;
      }
      await accountProvider.update(accountPersist);
      if (_deletingAll || generation != _generation) return false;
      await _fetchUnlocked(generation);
      return !_deletingAll &&
          generation == _generation &&
          now?.id == accountPersist.id;
    });
  }

  @action
  deleteSingle(int id) async {
    final generation = ++_generation;
    if (now?.id == id) now = null;
    accounts.removeWhere((account) => account.id == id);
    if (index >= accounts.length) index = 0;
    await _serialize(() async {
      await accountProvider.open();
      await accountProvider.delete(id);
      await _fetchUnlocked(generation);
    });
  }

  @action
  Future<void> fetch() async {
    if (_deletingAll) return;
    final generation = _generation;
    await _serialize(() => _fetchUnlocked(generation));
  }

  Future<void> _fetchUnlocked(int generation) async {
    if (_deletingAll || generation != _generation) return;
    feching = true;
    try {
      await accountProvider.open();
      List<AccountPersist> list = await accountProvider.getAllAccount();
      await Prefer.init();
      if (_deletingAll || generation != _generation) return;
      accounts.clear();
      accounts.addAll(list);
      var i = Prefer.getInt('account_select_num');
      if (list.isNotEmpty) {
        index = i != null && i >= 0 && i < list.length ? i : 0;
        now = list[index];
      } else {
        index = 0;
        now = null;
      }
    } catch (e) {
    } finally {
      feching = false;
    }
  }
}
