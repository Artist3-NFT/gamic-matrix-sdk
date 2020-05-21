import 'dart:convert';
import 'package:canonical_json/canonical_json.dart';
import 'package:olm/olm.dart' as olm;

import '../client.dart';
import '../database/database.dart' show DbUserDeviceKey, DbUserDeviceKeysKey, DbUserCrossSigningKey;
import '../event.dart';
import 'key_verification.dart';

class DeviceKeysList {
  Client client;
  String userId;
  bool outdated = true;
  Map<String, DeviceKeys> deviceKeys = {};
  Map<String, CrossSigningKey> crossSigningKeys = {};

  DeviceKeysList.fromDb(DbUserDeviceKey dbEntry, List<DbUserDeviceKeysKey> childEntries, List<DbUserCrossSigningKey> crossSigningEntries, Client cl) {
    client = cl;
    userId = dbEntry.userId;
    outdated = dbEntry.outdated;
    deviceKeys = {};
    for (final childEntry in childEntries) {
      final entry = DeviceKeys.fromDb(childEntry, client);
      if (entry.isValid) {
        deviceKeys[childEntry.deviceId] = entry;
      } else {
        outdated = true;
      }
    }
    for (final crossSigningEntry in crossSigningEntries) {
      final entry = CrossSigningKey.fromDb(crossSigningEntry, client);
      if (entry.isValid) {
        crossSigningKeys[crossSigningEntry.publicKey] = entry;
      } else {
        outdated = true;
      }
    }
  }

  DeviceKeysList.fromJson(Map<String, dynamic> json, Client cl) {
    client = cl;
    userId = json['user_id'];
    outdated = json['outdated'];
    deviceKeys = {};
    for (final rawDeviceKeyEntry in json['device_keys'].entries) {
      deviceKeys[rawDeviceKeyEntry.key] =
          DeviceKeys.fromJson(rawDeviceKeyEntry.value, client);
    }
  }

  Map<String, dynamic> toJson() {
    var map = <String, dynamic>{};
    final data = map;
    data['user_id'] = userId;
    data['outdated'] = outdated ?? true;

    var rawDeviceKeys = <String, dynamic>{};
    for (final deviceKeyEntry in deviceKeys.entries) {
      rawDeviceKeys[deviceKeyEntry.key] = deviceKeyEntry.value.toJson();
    }
    data['device_keys'] = rawDeviceKeys;
    return data;
  }

  @override
  String toString() => json.encode(toJson());

  DeviceKeysList(this.userId);
}

abstract class _SignedKey {
  Client client;
  String userId;
  String identifier;
  Map<String, dynamic> content;
  Map<String, String> keys;
  Map<String, dynamic> signatures;
  Map<String, dynamic> validSignatures;
  bool verified;
  bool blocked;

  String get ed25519Key => keys['ed25519:$identifier'];

  bool get crossVerified {
    try {
      return hasValidSignatureChain();
    } catch (err, stacktrace) {
      print('[Cross Signing] Error during trying to determine signature chain: ' + err.toString());
      print(stacktrace);
      return false;
    }
  }

  String _getSigningContent() {
    final data = Map<String, dynamic>.from(content);
    data.remove('verified');
    data.remove('blocked');
    data.remove('unsigned');
    data.remove('signatures');
    return String.fromCharCodes(canonicalJson.encode(data));
  }

  bool _verifySignature(String pubKey, String signature) {
    final olmutil = olm.Utility();
    var valid = false;
    try {
      olmutil.ed25519_verify(pubKey, _getSigningContent(), signature);
      valid = true;
    } finally {
      olmutil.free();
    }
    return valid;
  }

  bool hasValidSignatureChain({Set<String> visited}) {
    if (visited == null) {
      visited = Set<String>();
    }
    final setKey = '${userId};${identifier}';
    if (visited.contains(setKey)) {
      return false; // prevent recursion
    }
    visited.add(setKey);
    for (final signatureEntries in signatures.entries) {
      final otherUserId = signatureEntries.key;
      if (!(signatureEntries.value is Map) || !client.userDeviceKeys.containsKey(otherUserId)) {
        continue;
      }
      for (final signatureEntry in signatureEntries.value.entries) {
        final fullKeyId = signatureEntry.key;
        final signature = signatureEntry.value;
        if (!(fullKeyId is String) || !(signature is String)) {
          continue;
        }
        final keyId = fullKeyId.substring('ed25519:'.length);
        _SignedKey key;
        if (client.userDeviceKeys[otherUserId].deviceKeys.containsKey(keyId)) {
          key = client.userDeviceKeys[otherUserId].deviceKeys[keyId];
        } else if (client.userDeviceKeys[otherUserId].crossSigningKeys.containsKey(keyId)) {
          key = client.userDeviceKeys[otherUserId].crossSigningKeys[keyId];
        } else {
          continue;
        }
        if (key.blocked) {
          continue; // we can't be bothered about this keys signatures
        }
        var haveValidSignature = false;
        var gotSignatureFromCache = false;
        if (validSignatures != null && validSignatures.containsKey(otherUserId) && validSignatures[otherUserId].containsKey(fullKeyId)) {
          if (validSignatures[otherUserId][fullKeyId] == true) {
            haveValidSignature = true;
            gotSignatureFromCache = true;
          } else if (validSignatures[otherUserId][fullKeyId] == false) {
            gotSignatureFromCache = true;
          }
        }
        if (!gotSignatureFromCache) {
          // validate the signature manually
          haveValidSignature = _verifySignature(key.ed25519Key, signature);
        }
        if (!haveValidSignature) {
          // no valid signature, this key is useless
          continue;
        }

        if (key.verified) {
          return true; // we verified this key and it is valid...all checks out!
        }
        // or else we just recurse into that key and chack if it works out
        final haveChain = key.hasValidSignatureChain(visited: visited);
        if (haveChain) {
          return true;
        }
      }
    }
    return false;
  }
}

class CrossSigningKey extends _SignedKey {
  String get publicKey => identifier;
  List<String> usage;

  bool get isValid => userId != null && publicKey != null && keys != null && ed25519Key != null;

  Future<void> setVerified(bool newVerified) {
    verified = newVerified;
    return client.database?.setVerifiedUserCrossSigningKey(newVerified, client.id, userId, publicKey);
  }

  Future<void> setBlocked(bool newBlocked) {
    blocked = newBlocked;
    return client.database?.setBlockedUserCrossSigningKey(newBlocked, client.id, userId, publicKey);
  }

  CrossSigningKey.fromDb(DbUserCrossSigningKey dbEntry, Client cl) {
    client = cl;
    final json = Event.getMapFromPayload(dbEntry.content);
    content = Map<String, dynamic>.from(json);
    userId = dbEntry.userId;
    identifier = dbEntry.publicKey;
    usage = json['usage'].cast<String>();
    keys = json['keys'] != null ? Map<String, String>.from(json['keys']) : null;
    signatures = json['signatures'] != null ? Map<String, dynamic>.from(json['signatures']) : null;
    validSignatures = null;
    if (dbEntry.validSignatures != null) {
      final validSignaturesContent = Event.getMapFromPayload(dbEntry.validSignatures);
      if (validSignaturesContent is Map) {
        validSignatures = validSignaturesContent.cast<String, dynamic>();
      }
    }
    verified = dbEntry.verified;
    blocked = dbEntry.blocked;
  }

  CrossSigningKey.fromJson(Map<String, dynamic> json, Client cl) {
    client = cl;
    content = Map<String, dynamic>.from(json);
    userId = json['user_id'];
    usage = json['usage'].cast<String>();
    keys = json['keys'] != null ? Map<String, String>.from(json['keys']) : null;
    signatures = json['signatures'] != null
        ? Map<String, dynamic>.from(json['signatures'])
        : null;
    validSignatures = null;
    verified = json['verified'] ?? false;
    blocked = json['blocked'] ?? false;
    if (keys != null) {
      identifier = keys.values.first;
    }
  }

  Map<String, dynamic> toJson() {
    final data = Map<String, dynamic>.from(content);
    data['user_id'] = userId;
    data['usage'] = usage;
    if (keys != null) {
      data['keys'] = keys;
    }
    if (signatures != null) {
      data['signatures'] = signatures;
    }
    data['verified'] = verified;
    data['blocked'] = blocked;
    return data;
  }
}

class DeviceKeys extends _SignedKey {
  String get deviceId => identifier;
  List<String> algorithms;
  Map<String, dynamic> unsigned;

  String get curve25519Key => keys['curve25519:$deviceId'];

  bool get isValid => userId != null && deviceId != null && keys != null && curve25519Key != null && ed25519Key != null;

  Future<void> setVerified(bool newVerified) {
    verified = newVerified;
    return client.database?.setVerifiedUserDeviceKey(newVerified, client.id, userId, deviceId);
  }

  Future<void> setBlocked(bool newBlocked) {
    blocked = newBlocked;
    for (var room in client.rooms) {
      if (!room.encrypted) continue;
      if (room.getParticipants().indexWhere((u) => u.id == userId) != -1) {
        room.clearOutboundGroupSession();
      }
    }
    return client.database?.setBlockedUserDeviceKey(newBlocked, client.id, userId, deviceId);
  }

  DeviceKeys.fromDb(DbUserDeviceKeysKey dbEntry, Client cl) {
    client = cl;
    final json = Event.getMapFromPayload(dbEntry.content);
    content = Map<String, dynamic>.from(json);
    userId = dbEntry.userId;
    identifier = dbEntry.deviceId;
    algorithms = json['algorithms'].cast<String>();
    keys = json['keys'] != null ? Map<String, String>.from(json['keys']) : null;
    signatures = json['signatures'] != null
        ? Map<String, dynamic>.from(json['signatures'])
        : null;
    unsigned = json['unsigned'] != null
        ? Map<String, dynamic>.from(json['unsigned'])
        : null;
    validSignatures = null;
    if (dbEntry.validSignatures != null) {
      final validSignaturesContent = Event.getMapFromPayload(dbEntry.validSignatures);
      if (validSignaturesContent is Map) {
        validSignatures = validSignaturesContent.cast<String, dynamic>();
      }
    }
    verified = dbEntry.verified;
    blocked = dbEntry.blocked;
  }

  DeviceKeys.fromJson(Map<String, dynamic> json, Client cl) {
    client = cl;
    content = Map<String, dynamic>.from(json);
    userId = json['user_id'];
    identifier = json['device_id'];
    algorithms = json['algorithms'].cast<String>();
    keys = json['keys'] != null ? Map<String, String>.from(json['keys']) : null;
    signatures = json['signatures'] != null
        ? Map<String, dynamic>.from(json['signatures'])
        : null;
    unsigned = json['unsigned'] != null
        ? Map<String, dynamic>.from(json['unsigned'])
        : null;
    verified = json['verified'] ?? false;
    blocked = json['blocked'] ?? false;
  }

  Map<String, dynamic> toJson() {
    final data = Map<String, dynamic>.from(content);
    data['user_id'] = userId;
    data['device_id'] = deviceId;
    data['algorithms'] = algorithms;
    if (keys != null) {
      data['keys'] = keys;
    }
    if (signatures != null) {
      data['signatures'] = signatures;
    }
    if (unsigned != null) {
      data['unsigned'] = unsigned;
    }
    data['verified'] = verified;
    data['blocked'] = blocked;
    return data;
  }

  KeyVerification startVerification() {
    final request = KeyVerification(client: client, userId: userId, deviceId: deviceId);
    request.start();
    client.addKeyVerificationRequest(request);
    return request;
  }
}
