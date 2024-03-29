import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'util.dart';
import 'package:hive/hive.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {

  FirebaseChatCore._privateConstructor() {
    var box = Hive.box('auth_box');
    // FirebaseAuth.instance.authStateChanges().listen((User? user) {
    //   firebaseUser = user;
    // });
    if (box.containsKey('id')) {
      var userId = box.get('id').toString();
      firebaseUser = types.User(id: userId);
    }
  }

  /// Current logged in user in Firebase. Does not update automatically.
  /// Use [FirebaseAuth.authStateChanges] to listen to the state changes.
  types.User? firebaseUser;
  //  = FirebaseAuth.instance.currentUser;

  // /// Singleton instance
  static final FirebaseChatCore instance =
      FirebaseChatCore._privateConstructor();

  void refreshUser() {
    if (firebaseUser != null) {
      fetchUser(firebaseUser!.id).then((user) => firebaseUser = user);
    }
  }

  void updateUser(String id) {
    final box = Hive.box('auth_box');
    box.put('id', id);
    firebaseUser = types.User(id: id);
    fetchUser(id).then((user) => firebaseUser = user);
  }

  void logoutUser() {
    final box = Hive.box('auth_box');
    box.delete('id');
    firebaseUser = null;
  }

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final roomUsers = [firebaseUser!] + users;

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': 'group',
      'userIds': roomUsers.map((u) => u.id).toList(),
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    types.User otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final query = await FirebaseFirestore.instance
        .collection('rooms')
        .where('userIds', arrayContains: firebaseUser!.id)
        .get();

    final rooms = await processRoomsQuery(firebaseUser!, query);

    try {
      return rooms.firstWhere((room) {
        if (room.type == types.RoomType.group) return false;

        final userIds = room.users.map((u) => u.id);
        return userIds.contains(firebaseUser!.id) &&
            userIds.contains(otherUser.id);
      });
    } catch (e) {
      // Do nothing if room does not exist
      // Create a new room instead
    }

    final users = [firebaseUser!, otherUser];

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': 'direct',
      'userIds': users.map((u) => u.id).toList(),
    });

    return types.Room(
      id: room.id,
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(types.User user) async {
    await FirebaseFirestore.instance.collection('users').doc(user.id).set({
      'avatarUrl': user.avatarUrl,
      'firstName': user.firstName,
      'lastName': user.lastName,
    });
  }

  Future<void> updateUserInFireStore(types.User user, String firstName, String lastName) async {
    await FirebaseFirestore.instance.collection('users').doc(user.id).update({
      'firstName': firstName,
      'lastName': lastName,
    });
  }

  /// Returns a stream of messages from Firebase for a given room
  Stream<List<types.Message>> messages(String roomId) {
    return FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map(
      (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
          (previousValue, element) {
            final data = element.data();
            data['id'] = element.id;
            data['timestamp'] = element['timestamp']?.seconds;
            return [...previousValue, types.Message.fromJson(data)];
          },
        );
      },
    );
  }

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned.
  Stream<List<types.Room>> rooms() {
    if (firebaseUser == null) return const Stream.empty();

    return FirebaseFirestore.instance
        .collection('rooms')
        .where('userIds', arrayContains: firebaseUser!.id)
        .snapshots()
        .asyncMap((query) => processRoomsQuery(firebaseUser!, query));
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(dynamic partialMessage, String roomId) async {
    if (firebaseUser == null) return;

    types.Message? message;

    if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        authorId: firebaseUser!.id,
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        authorId: firebaseUser!.id,
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        authorId: firebaseUser!.id,
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'id');
      messageMap['timestamp'] = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance
          .collection('rooms/$roomId/messages')
          .add(messageMap);
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(types.Message message, String roomId) async {
    if (firebaseUser == null) return;
    if (message.authorId != firebaseUser!.id) return;

    final messageMap = message.toJson();
    messageMap.removeWhere((key, value) => key == 'id' || key == 'timestamp');

    await FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .doc(message.id)
        .update(messageMap);
  }

  /// Returns a stream of all users from Firebase
  Stream<List<types.User>> users() {
    if (firebaseUser == null) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.User>>(
            [],
            (previousValue, element) {
              if (firebaseUser!.id == element.id) return previousValue;

              return [...previousValue, processUserDocument(element)];
            },
          ),
        );
  }
}
