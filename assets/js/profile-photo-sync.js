import { collection, collectionGroup, doc, FieldPath, getDocs, query, where, writeBatch } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";

export async function syncProfilePhotoReferences(db, userId, photoURL) {
    const [blogs, stories, playlists, episodes, comments, conversations] = await Promise.all([
        getDocs(collection(db, "blogs")),
        getDocs(query(collection(db, "stories"), where("authorUid", "==", userId))),
        getDocs(query(collection(db, "playlists"), where("authorUid", "==", userId))),
        getDocs(query(collectionGroup(db, "episodes"), where("authorUid", "==", userId))),
        getDocs(query(collectionGroup(db, "comments"), where("userUid", "==", userId))),
        getDocs(query(collection(db, "conversations"), where("participants", "array-contains", userId)))
    ]);

    const updates = [];
    blogs.forEach(blogDoc => {
        const data = blogDoc.data();
        const changes = {};
        if (data.authorUid === userId && data.authorPhoto !== photoURL) changes.authorPhoto = photoURL;

        if (Array.isArray(data.comments)) {
            let commentsChanged = false;
            const updatedComments = data.comments.map(comment => {
                let updatedComment = comment;
                if (comment.userUid === userId && comment.photo !== photoURL) {
                    updatedComment = { ...updatedComment, photo: photoURL };
                }
                if (Array.isArray(comment.replies)) {
                    const replies = comment.replies.map(reply => {
                        if (reply.userUid === userId && reply.photo !== photoURL) {
                            return { ...reply, photo: photoURL };
                        }
                        return reply;
                    });
                    if (replies.some((reply, index) => reply !== comment.replies[index])) {
                        updatedComment = { ...updatedComment, replies };
                    }
                }
                if (updatedComment !== comment) commentsChanged = true;
                return updatedComment;
            });
            if (commentsChanged) changes.comments = updatedComments;
        }

        if (Object.keys(changes).length) updates.push({ ref: doc(db, "blogs", blogDoc.id), changes });
    });

    stories.forEach(storyDoc => {
        if (storyDoc.data().authorPhoto !== photoURL) {
            updates.push({ ref: doc(db, "stories", storyDoc.id), changes: { authorPhoto: photoURL } });
        }
    });

    playlists.forEach(playlistDoc => {
        const data = playlistDoc.data();
        if (data.authorUid === userId && data.authorPhoto !== photoURL) {
            updates.push({ ref: doc(db, "playlists", playlistDoc.id), changes: { authorPhoto: photoURL } });
        }
    });

    episodes.forEach(episodeDoc => {
        if (episodeDoc.data().authorPhoto !== photoURL) {
            updates.push({ ref: episodeDoc.ref, changes: { authorPhoto: photoURL } });
        }
    });

    comments.forEach(commentDoc => {
        if (commentDoc.data().photo !== photoURL) {
            updates.push({ ref: commentDoc.ref, changes: { photo: photoURL } });
        }
    });

    conversations.forEach(conversationDoc => {
        const data = conversationDoc.data();
        const participant = data.participantDetails?.[userId];
        if (participant && participant.photoURL !== photoURL) {
            updates.push({
                ref: doc(db, "conversations", conversationDoc.id),
                fieldPath: new FieldPath("participantDetails", userId, "photoURL"),
                value: photoURL
            });
        }
    });

    for (let offset = 0; offset < updates.length; offset += 400) {
        const batch = writeBatch(db);
        updates.slice(offset, offset + 400).forEach(({ ref, changes, fieldPath, value }) => {
            if (fieldPath) {
                batch.update(ref, fieldPath, value);
            } else {
                batch.update(ref, changes);
            }
        });
        await batch.commit();
    }

    return updates.length;
}
