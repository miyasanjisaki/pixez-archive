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

import 'package:dio/dio.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/account.dart';
import 'package:pixez/models/error_message.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/network/oauth_client.dart';

class RefreshTokenInterceptor extends InterceptorsWrapper {
  static const _authRetryKey = 'pixez.authRetry';
  static const _networkRetryKey = 'pixez.networkRetry';
  static Future<String?>? _refreshInFlight;

  Future<String?> getToken() async {
    final token = accountStore.now?.accessToken;
    if (token != null) return 'Bearer $token';

    // accountStore can still be initializing when the first request arrives.
    // Reuse its provider instead of opening and closing another SQLite handle;
    // sqflite databases are single-instance by default.
    if (accountStore.accounts.isEmpty) {
      await accountStore.fetch();
    }
    final all = accountStore.accounts;
    if (all.isEmpty) return null;
    final index = accountStore.index >= 0 && accountStore.index < all.length
        ? accountStore.index
        : 0;
    return 'Bearer ${all[index].accessToken}';
  }

  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (!options.path.contains('v1/walkthrough/illusts')) {
      options.headers[OAuthClient.AUTHORIZATION] = await getToken();
      if (options.headers[OAuthClient.AUTHORIZATION] == null) {
        return handler.reject(DioException(requestOptions: options));
      }
    }
    return handler.next(options);
  }

  int bti(bool value) => value ? 1 : 0;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (_isExpiredOAuthResponse(err) &&
        err.requestOptions.extra[_authRetryKey] != true) {
      try {
        final currentToken = await getToken();
        final requestToken =
            err.requestOptions.headers[OAuthClient.AUTHORIZATION];
        final token = currentToken != null && currentToken != requestToken
            ? currentToken
            : await _refreshTokenSingleFlight();

        if (token != null) {
          final options = err.requestOptions;
          options.headers[OAuthClient.AUTHORIZATION] = token;
          options.extra[_authRetryKey] = true;
          final response = await apiClient.httpClient.fetch<dynamic>(options);
          return handler.resolve(response);
        }
      } catch (error, stackTrace) {
        LPrinter.d('Token refresh failed: $error');
        LPrinter.d(stackTrace);
      }
      return handler.next(err);
    }

    final retryCount =
        err.requestOptions.extra[_networkRetryKey] as int? ?? 0;
    if (_isTransientConnectionError(err) &&
        _isIdempotentRequest(err.requestOptions) &&
        retryCount < 2) {
      try {
        final options = err.requestOptions;
        options.extra[_networkRetryKey] = retryCount + 1;
        final response = await apiClient.httpClient.fetch<dynamic>(options);
        return handler.resolve(response);
      } catch (error, stackTrace) {
        LPrinter.d('Network retry failed: $error');
        LPrinter.d(stackTrace);
      }
    }

    return handler.next(err);
  }

  bool _isExpiredOAuthResponse(DioException error) {
    if (error.response?.statusCode != 400) return false;
    try {
      final message = ErrorMessage.fromJson(error.response!.data).error.message;
      return message?.contains('OAuth') ?? false;
    } catch (_) {
      return false;
    }
  }

  bool _isTransientConnectionError(DioException error) {
    return error.type == DioExceptionType.connectionError ||
        (error.message?.contains(
              'Connection closed before full header was received',
            ) ??
            false);
  }

  bool _isIdempotentRequest(RequestOptions options) {
    final method = options.method.toUpperCase();
    return method == 'GET' || method == 'HEAD';
  }

  Future<String?> _refreshTokenSingleFlight() async {
    final pending = _refreshInFlight;
    if (pending != null) return pending;

    final refresh = _refreshToken();
    _refreshInFlight = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshInFlight, refresh)) {
        _refreshInFlight = null;
      }
    }
  }

  Future<String?> _refreshToken() async {
    final accountPersist = accountStore.now;
    if (accountPersist == null) return null;

    final client = OAuthClient();
    await client.createDioClient();
    final response = await client.postRefreshAuthToken(
      refreshToken: accountPersist.refreshToken,
      deviceToken: accountPersist.deviceToken,
    );
    final accountResponse = Account.fromJson(response.data).response;
    final user = accountResponse.user;
    final updated = await accountStore.updateSingle(
      AccountPersist(
        userId: user.id,
        userImage: user.profileImageUrls.px170x170,
        accessToken: accountResponse.accessToken,
        refreshToken: accountResponse.refreshToken,
        deviceToken: '',
        passWord: 'no more',
        name: user.name,
        account: user.account,
        mailAddress: user.mailAddress,
        isPremium: bti(user.isPremium),
        xRestrict: user.xRestrict,
        isMailAuthorized: bti(user.isMailAuthorized),
        id: accountPersist.id,
      ),
    );
    if (!updated) return null;
    return 'Bearer ${accountResponse.accessToken}';
  }
}
