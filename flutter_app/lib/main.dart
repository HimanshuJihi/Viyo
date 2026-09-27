import 'package:flutter/material.dart';

void main() => runApp(const ViyouApp());

class ViyouApp extends StatelessWidget {
  const ViyouApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Viyou.in',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff050505),
        fontFamily: 'Arial',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff6366f1),
          brightness: Brightness.dark,
        ),
      ),
      home: const ViyouHomePage(),
    );
  }
}

class ViyouHomePage extends StatefulWidget {
  const ViyouHomePage({super.key});

  @override
  State<ViyouHomePage> createState() => _ViyouHomePageState();
}

class _ViyouHomePageState extends State<ViyouHomePage> {
  int _selectedTab = 0;
  String _selectedCategory = 'All';
  bool _likedFirstPost = false;
  final _searchController = TextEditingController();

  final _categories = const [
    'All',
    'Entertainment',
    'Music',
    'Vlogs',
    'Gaming',
    'Education',
    'Sports',
    'News & Politics',
    'Science & Technology',
    'Comedy',
    'Travel & Events',
    'Fashion & Beauty',
    'Food',
    'Devotional',
    'Gym & Fitness',
    'Health',
    'Podcasts',
    'Others',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 850;
        return Scaffold(
          appBar: _buildHeader(isDesktop),
          body: SafeArea(
            top: false,
            bottom: false,
            child: _selectedTab == 0
                ? _buildHome(isDesktop)
                : _buildPlaceholderTab(),
          ),
          bottomNavigationBar: isDesktop ? null : _buildBottomNavigation(),
        );
      },
    );
  }

  PreferredSizeWidget _buildHeader(bool isDesktop) {
    return AppBar(
      elevation: 0,
      backgroundColor: const Color(0xff0f0f0f),
      titleSpacing: isDesktop ? 22 : 14,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _showMenu(context),
            icon: const Icon(Icons.menu_rounded, size: 26),
            tooltip: 'Menu',
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.play_circle_fill_rounded,
            color: Color(0xfff59e0b),
            size: 27,
          ),
          const SizedBox(width: 8),
          const Text(
            'Viyou.in',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
        ],
      ),
      actions: [
        if (isDesktop) SizedBox(width: 360, child: _searchField()),
        if (!isDesktop)
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search',
          ),
        IconButton(
          onPressed: () => _showMessage(context, 'No new notifications'),
          icon: const Badge(
            label: Text('3'),
            child: Icon(Icons.notifications_none_rounded),
          ),
          tooltip: 'Notifications',
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: _searchController,
        onSubmitted: (value) => _showMessage(
          context,
          value.isEmpty ? 'Search Viyou' : 'Searching for "$value"',
        ),
        decoration: InputDecoration(
          hintText: 'Search',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          filled: true,
          fillColor: const Color(0xff181818),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildHome(bool isDesktop) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 28 : 14,
        20,
        isDesktop ? 28 : 14,
        100,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStories(),
              const SizedBox(height: 28),
              _sectionTitle(
                'Trending',
                Icons.local_fire_department_rounded,
                const Color(0xfff09433),
              ),
              const SizedBox(height: 12),
              _buildTrending(),
              const SizedBox(height: 30),
              _sectionTitle(
                'Latest from creators',
                Icons.auto_awesome_rounded,
                const Color(0xff6366f1),
              ),
              const SizedBox(height: 14),
              _buildCategories(),
              const SizedBox(height: 18),
              isDesktop ? _buildDesktopFeed() : _buildMobileFeed(),
              const SizedBox(height: 34),
              Center(
                child: Text(
                  '© Viyou.in  Empowering Creators',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStories() {
    final stories = [
      'Your story',
      'Aarav',
      'Meera',
      'Rohan',
      'Ishita',
      'Kabir',
      'Zoya',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Stories',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: stories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 18),
            itemBuilder: (context, index) {
              final isFirst = index == 0;
              return GestureDetector(
                onTap: () => _showMessage(
                  context,
                  isFirst ? 'Create a new story' : '${stories[index]}\'s story',
                ),
                child: Column(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: isFirst
                                ? null
                                : const LinearGradient(
                                    colors: [
                                      Color(0xfff09433),
                                      Color(0xffbc1888),
                                    ],
                                  ),
                            color: isFirst ? const Color(0xff262626) : null,
                          ),
                          child: CircleAvatar(
                            radius: 31,
                            backgroundColor: const Color(0xff151515),
                            child: isFirst
                                ? const Icon(
                                    Icons.add_rounded,
                                    color: Color(0xffa855f7),
                                    size: 27,
                                  )
                                : Text(
                                    stories[index][0],
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 20,
                                    ),
                                  ),
                          ),
                        ),
                        if (isFirst)
                          const Positioned(
                            right: -2,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: Color(0xff6366f1),
                              child: Icon(Icons.add, size: 14),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 66,
                      child: Text(
                        stories[index],
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, IconData icon, Color color) => Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget _buildTrending() {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 5,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) => _trendingCard(index),
      ),
    );
  }

  Widget _trendingCard(int index) {
    final colors = [
      const Color(0xfff97316),
      const Color(0xff0ea5e9),
      const Color(0xff8b5cf6),
      const Color(0xff10b981),
      const Color(0xffef4444),
    ];
    final labels = [
      'Creator spotlight',
      'Indie music',
      'Tech today',
      'Travel diaries',
      'Food stories',
    ];
    return Container(
      width: 220,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors[index], const Color(0xff151515)],
        ),
      ),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            '#${index + 1}  ${labels[index]}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '${12 + index * 7}K posts',
            style: TextStyle(
              color: Colors.white.withValues(alpha: .72),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategories() => SizedBox(
    height: 38,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final category = _categories[index];
        final active = category == _selectedCategory;
        return ChoiceChip(
          label: Text(category),
          selected: active,
          onSelected: (_) => setState(() => _selectedCategory = category),
          selectedColor: const Color(0xff6366f1),
          backgroundColor: const Color(0xff151515),
          labelStyle: TextStyle(
            color: active ? Colors.white : Colors.grey[400],
            fontWeight: FontWeight.w600,
          ),
        );
      },
    ),
  );

  Widget _buildDesktopFeed() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          children: [_postCard(0), const SizedBox(height: 18), _postCard(1)],
        ),
      ),
      const SizedBox(width: 24),
      SizedBox(width: 290, child: _buildSidebar()),
    ],
  );

  Widget _buildMobileFeed() => Column(
    children: [_postCard(0), const SizedBox(height: 18), _postCard(1)],
  );

  Widget _buildSidebar() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xff101010),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: .06)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Suggested creators',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 16),
        ...['The Weekend Lens', 'Pixel Pantry', 'Code with Riya'].map(
          (name) => Padding(
            padding: const EdgeInsets.only(bottom: 15),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xff292929),
                  child: Text(name[0]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(
                  Icons.add_circle_outline_rounded,
                  color: Color(0xff6366f1),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _postCard(int index) {
    final titles = [
      'A quiet morning in the hills',
      'Building better habits, one day at a time',
    ];
    final names = ['Maya Sharma', 'Arjun Verma'];
    final liked = _likedFirstPost && index == 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff101010),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: index == 0
                    ? const Color(0xfff59e0b)
                    : const Color(0xff0ea5e9),
                child: Text(
                  names[index][0],
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      names[index],
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      index == 0 ? '2h ago' : '5h ago',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            titles[index],
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: index == 0
                      ? [const Color(0xff334155), const Color(0xffd97706)]
                      : [const Color(0xff172554), const Color(0xff0f766e)],
                ),
              ),
              child: Center(
                child: Icon(
                  index == 0
                      ? Icons.landscape_rounded
                      : Icons.lightbulb_outline_rounded,
                  size: 70,
                  color: Colors.white.withValues(alpha: .75),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                onPressed: () {
                  if (index == 0)
                    setState(() => _likedFirstPost = !_likedFirstPost);
                },
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border_rounded,
                  color: liked ? Colors.redAccent : Colors.white,
                ),
              ),
              Text(
                liked ? '129' : '${128 + index * 31}',
                style: TextStyle(color: Colors.grey[400]),
              ),
              const SizedBox(width: 18),
              const Icon(Icons.mode_comment_outlined, size: 20),
              const SizedBox(width: 6),
              Text(
                '${14 + index * 5}',
                style: TextStyle(color: Colors.grey[400]),
              ),
              const Spacer(),
              const Icon(Icons.share_outlined, size: 20),
              const SizedBox(width: 14),
              const Icon(Icons.bookmark_border_rounded, size: 20),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderTab() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          [
            Icons.home_rounded,
            Icons.bolt_rounded,
            Icons.add_box_outlined,
            Icons.chat_bubble_outline_rounded,
            Icons.person_outline_rounded,
          ][_selectedTab],
          size: 58,
          color: const Color(0xff6366f1),
        ),
        const SizedBox(height: 14),
        Text(
          ['Home', 'Flicks', 'Create', 'Messages', 'Profile'][_selectedTab],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'This screen is ready for the next UI pass',
          style: TextStyle(color: Colors.grey[500]),
        ),
      ],
    ),
  );

  Widget _buildBottomNavigation() => NavigationBar(
    backgroundColor: const Color(0xff0f0f0f),
    indicatorColor: const Color(0xff28215a),
    selectedIndex: _selectedTab,
    onDestinationSelected: (index) => setState(() => _selectedTab = index),
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home_rounded),
        label: 'Home',
      ),
      NavigationDestination(
        icon: Icon(Icons.bolt_outlined),
        selectedIcon: Icon(Icons.bolt_rounded),
        label: 'Flicks',
      ),
      NavigationDestination(
        icon: Icon(Icons.add_circle_outline_rounded),
        selectedIcon: Icon(Icons.add_circle_rounded),
        label: 'Create',
      ),
      NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline_rounded),
        selectedIcon: Icon(Icons.chat_bubble_rounded),
        label: 'Messages',
      ),
      NavigationDestination(
        icon: Icon(Icons.person_outline_rounded),
        selectedIcon: Icon(Icons.person_rounded),
        label: 'Profile',
      ),
    ],
  );

  void _showMenu(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xff151515),
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Watch History'),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Viyou'),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    ),
  );

  void _showMessage(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
        );
}
