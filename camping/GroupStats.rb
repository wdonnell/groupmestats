require 'rubygems' 
require 'bundler/setup'
require 'sqlite3'
require 'json'
require 'yaml'
require 'camping/session'
require 'set'
require 'erb'
require_relative '../bin/scraper.rb'
require 'logger'
Camping.goes :GroupStats

module GroupStats
    set :secret, "this is my secret."
    include Camping::Session
end

def GroupStats.create
    begin
        $config = YAML.load_file(File.join(File.expand_path(File.dirname(__FILE__)), 'web.yaml') )
    rescue Errno::ENOENT => e
        abort('Configuration file not found.  Exiting...')
    end

    begin
        $database_path = $config['groupme']['database']
        $database = SQLite3::Database.new( $database_path )
    rescue Errno::ENOENT => e
        abort('Did not specify a valid database file')
    end
    
    if !$config['groupme']['client_id'].nil?
        $client_id = $config['groupme']['client_id']
    else    
        abort('Did not specify a GroupMe client_id')
    end

    begin
	$logging_path = $config['camping-server']['log']
        $logger = Logger.new($logging_path)
    rescue
	abort('Log file not found.  Exiting...')
    end
end

module GroupStats::Controllers

  class Index < R '/'
    def get 
        if(@state.token == nil)
            client_id = $client_id
            template_path = File.join(File.expand_path(File.dirname(__FILE__)), 'authenticate.html')
            return ERB.new(File.read(template_path)).result(binding)
        else
	    @state.scraper = Scraper.new($database_path, @state.token, $logging_path)
            @state.user_id = @state.scraper.getUser
            File.open(File.join(File.expand_path(File.dirname(__FILE__)), 'index.html') )
        end
    end
  end
  
  class Authenticate < R '/authenticate'
    def get
        $logger = Logger.new($logging_path)
        @state.token = @input.access_token
        @state.scraper = Scraper.new($database_path, @state.token, $logging_path)
        @state.user_id = @state.scraper.getUser
        
        $logger.info "authenticating"
        $logger.info "@state.token = #{@state.token}"

        @state.groups = Array.new
        refreshGroupList()
        updateStateGroupList(@state.scraper.getGroups)

        return redirect Index
    end
  end

  def updateStateGroupList(grouplist)
    @state.groups = Array.new
        grouplist.each do |group|
            @state.groups.push(group['group_id'].to_i)
        end
    end
  
  def getGroups(group_id)
      if @state.groups.include?(group_id.to_i)
          return true
      else
          return false
      end
  end

  def scrapeAll()
      $logger.info "Scraping all groups for user #{@state.token}"
      groups = @state.scraper.getGroups

      groups.each do |group|
	  if !getGroups(group['group_id'])
              return 'nil'
          end
          
	  thr = Thread.new { @state.scraper.scrapeNewMessages(group['group_id']) }
      end
  end

  def refreshGroupList()
      $logger.info "Refreshing Grouplist for @state.token = #{@state.token}"
      groups = @state.scraper.getGroups
      groups.each do | group |
          @state.scraper.populateGroup(group['group_id'].to_i)
      end
      updateStateGroupList(groups)
      return groups.to_json
  end

  def parseTimeZone(timezone)
  
      #Timezone parsing bullshit
      if(timezone == nil)
          timezone = '04:00'
      else
          if timezone.to_i < 0
              if timezone.to_i < 9
                  timezone = "0#{@input.timezone.to_i.abs}:00"
              else
                  timezone = "#{@input.timezone.to_i.abs}:00"
              end
          else
              if timezone.to_i < 9
                  timezone = "-0#{@input.timezone.to_i.abs}:00"
              else
                  timezone = "-#{@input.timezone.to_i.abs}:00"
              end
          end
      end

      return timezone
  end

  class GroupFacts < R '/rest/groupfacts'
    def get ()
	totalimages = $database.execute(" SELECT count(*) AS totalimages
	    FROM messages 
	    WHERE messages.group_id = ? 
	    AND messages.image!='none'",
	    @input.groupid
        )[0][0]

	totalposts = $database.execute(" SELECT count(*) AS totalposts
	    FROM messages 
	    WHERE messages.group_id = ?
	    AND messages.user_id!='system'",
	    @input.groupid
	)[0][0]

        totalusers = $database.execute(" SELECT count(user_groups.user_id) AS totalusers 
	    FROM user_groups 
	    WHERE user_groups.group_id = ?",
            @input.groupid
        )[0][0]

	totalavatarchanges = $database.execute(" SELECT count(*) AS totalavatarchanges 
	    FROM messages 
	    WHERE messages.group_id = ?
	    AND messages.user_id='system' 
	    AND messages.text LIKE '%changed the group''s avatar%'",
	    @input.groupid
	)[0][0]

	totalgroupnamechanges = $database.execute(" SELECT count(*) AS totalgroupnamechanges
            FROM messages
            WHERE messages.group_id = ?
            AND messages.user_id='system'
            AND messages.text LIKE '%changed the group''s name%'",
            @input.groupid
        )[0][0]

        return {'totalimages' => totalimages, 'totalposts' => totalposts, 'totalusers' => totalusers, 'totalavatarchanges' => totalavatarchanges, 'totalgroupnamechanges' => totalgroupnamechanges}.to_json
    end
  end

  class GroupList < R '/rest/groupList'
    def get()
        $logger.info "Loading Grouplist from the database for @state.token = #{@state.token}"
        $database.results_as_hash = true
        result = $database.execute( "SELECT groups.group_id, groups.name, groups.image, groups.updated_at 
            FROM groups join user_groups on groups.group_id = user_groups.group_id 
            where user_groups.user_id = ?", 
            @state.user_id
        )
        $database.results_as_hash = false
        return result.to_json
    end
  end

  class RefreshGroupList < R '/rest/refreshGroupList'
    def get()
        return refreshGroupList()
    end
  end

  class ScrapeAll < R '/rest/scrapeall'
    def get()
        return scrapeAll()
    end
  end

#  class UserGroup < R '/rest/usergroup'
#    def get()
#        if(@input.days == nil)
#            @input.days = "9999999999"
#        end
#        if(@input.groupid == nil)
#            return false
#        end
#        
#        final_results = Array.new
#        users = $database.execute("select user_groups.user_id from user_groups where user_groups.group_id=?",
#            @input.groupid
#        )
#        
#        $logger.info "Pulling total posts, total likes, top posts, and top images in #(@input.groupid} for @state.token = #{@state.token}"
#        users.each do | userid |
#            result = Hash.new
#            $database.results_as_hash = true
#            result = $database.execute("SELECT * from users join user_groups using(user_id) where user_id = ? and group_id = ?",
#                userid,
#                @input.groupid,
#            )
#            result = result[0]
#    
#            total_posts = $database.execute("SELECT  count(messages.user_id) as count FROM messages WHERE messages.user_id=? AND messages.created_at > datetime('now', ?) AND messages.group_id=?",
#                userid,
#                "-" + @input.days + " day",
#                @input.groupid
#            )[0][0]
#            result.merge!(:total_posts => total_posts)
#            
#            total_likes_received = $database.execute("select count(likes.user_id) as count from likes left join messages on messages.message_id=likes.message_id where messages.created_at > datetime('now', ?) AND messages.user_id=? AND messages.group_id=?",
#                "-" + @input.days + " day",
#                userid,
#                @input.groupid
#            )[0][0]
#            result.merge!(:total_likes_received => total_likes_received)
#
#            if (total_likes_received.to_f == 0 || total_posts.to_f == 0)
#                result.merge!(:likes_to_posts_ratio => 0)
#            else
#                result.merge!(:likes_to_posts_ratio => total_likes_received.to_f/total_posts.to_f)
#            end
#
#            top_post = $database.execute("select count(likes.user_id) as count, messages.text from likes join messages on messages.message_id=likes.message_id WHERE messages.user_id=? and messages.group_id=? and messages.image=='none' AND messages.created_at > datetime('now', ?) group by messages.message_id order by count desc limit 1",
#                userid,
#                @input.groupid,
#                "-" + @input.days + " day"
#            )
#            if !top_post.empty?
#                result.merge!(:top_post_likes => top_post[0][0])
#                result.merge!(:top_post => top_post[0][1])
#            end
#
#            total_posts_for_group = $database.execute("SELECT count(*) from messages where messages.group_id=? AND messages.user_id != 'system' AND messages.created_at > datetime('now', ?)",
#                @input.groupid,
#                "-" + @input.days + " day"
#            )[0][0]
#            result.merge!(:post_percentage => ((total_posts.to_f/total_posts_for_group.to_f) * 100).round(2) )
#
#            final_results.push(result)
#        end
#        $database.results_as_hash = false
#
#        return final_results.to_json
#    end
#  end
#
  class User < R '/rest/user'
    def get()
        ifGroup = true
        if(@input.userid == nil)
            @input.userid = @state.user_id
        end
        if(@input.groupid == nil)
            ifGroup = false
        end
        
        result = Hash.new
        $database.results_as_hash = true
        if ifGroup
            $logger.info "Grabbing user-data for userid #{@input.userid} in #{@input.groupid} for @state.token = #{@state.token}" 
            userInfo = $database.execute("SELECT user_groups.name as name, users.avatar_url as avatar_url
            	FROM users
            	JOIN user_groups USING(user_id) 
            	    WHERE user_id = ? 
            	    AND group_id = ?",
            @input.userid,
            @input.groupid
            )[0]
       
            total_posts = $database.execute("SELECT count(messages.user_id) AS count 
            	FROM messages 
            	    WHERE messages.user_id=? 
            	    AND messages.group_id=?",
            @input.userid,
            @input.groupid
            )[0][0]
        
            total_likes_received = $database.execute("SELECT count(likes.user_id) AS count 
            	FROM likes 
            	LEFT JOIN messages ON messages.message_id=likes.message_id 
            	    WHERE messages.user_id=? 
            	    AND messages.group_id=?",
            @input.userid,
            @input.groupid
            )[0][0]
            
            if (total_likes_received.to_f == 0 || total_posts.to_f == 0)
               result.merge!(:likes_to_posts_ratio => 0)
            else
               result.merge!(:likes_to_posts_ratio => total_likes_received.to_f/total_posts.to_f)
            end

            top_post = $database.execute("SELECT count(likes.user_id) AS count, messages.text 
                FROM likes 
                JOIN messages ON messages.message_id=likes.message_id 
                    WHERE messages.user_id=? 
                    AND messages.group_id=?
                    AND messages.image=='none' 
                GROUP BY messages.message_id 
                ORDER BY count DESC LIMIT 5",
            @input.userid,
            @input.groupid,
            )
      
            top_images = $database.execute("SELECT count(likes.user_id) AS count, messages.text, messages.image
                FROM likes
                JOIN messages ON messages.message_id=likes.message_id
                    WHERE messages.user_id = ?
                    AND messages.group_id = ?
                    AND messages.image!='none'
                GROUP BY messages.message_id
                ORDER BY count DESC LIMIT 6", 
            @input.userid,
            @input.groupid
            )
 
            total_posts_for_group = $database.execute("SELECT count(*) 
            	FROM messages 
            	    WHERE messages.group_id=? 
            	    AND messages.user_id != 'system'",
            @input.groupid
            )[0][0]
	
    	    group_name = $database.execute("SELECT groups.name 
	        	FROM groups 
		            WHERE groups.group_id = ?",
		    @input.groupid
	        )[0][0]

            num_of_images = $database.execute("SELECT count(messages.image) 
                FROM messages 
                    WHERE messages.user_id = ?
                    AND messages.group_id = ?
                    AND messages.image != 'none'",
            @input.userid,
            @input.groupid
            )[0][0]

            $database.results_as_hash = false

            heatmap = $database.execute( "SELECT strftime('%w',messages.created_at) AS date,strftime('%H',messages.created_at, ?) AS hour, count(message_id) 
                FROM messages
                JOIN groups USING(group_id)
                    WHERE user_id = ?
                    AND messages.group_id = ?
                    AND messages.user_id != 'system'
                GROUP BY strftime('%w',messages.created_at), strftime('%H',messages.created_at)
                ORDER BY strftime('%w',messages.created_at) asc, strftime('%H',messages.created_at)",
            parseTimeZone(@input.timezone),
            @input.userid,
            @input.groupid,
            )
            #todo: enforce user id
            heatmap.each do |a|
                a[1] = a[1].to_i
                a[0] = a[0].to_i
            end

            # Need to loop through the returned values, and add 0s for any missing day/hour combos
            i, j = 0, 0
            while (i < 7)
                while (j < 24)
                    check = true
                    heatmap.each do | count |
                        if (count[0] == i && count[1] == j)
                            check = false
                        end
                    end
                    if check
                        heatmap.push([i,j,0])
                    end
                    j += 1
                end
                i += 1
                j = 0
            end

            daily_posts = $database.execute( "SELECT strftime('%H', messages.created_at, ? ) AS time, count(strftime('%H', messages.created_at, '-04:00')) 
                FROM messages 
                    WHERE messages.user_id = ?
                    AND messages.group_id = ? 
                    AND messages.user_id != 'system' 
                GROUP BY strftime('%H', messages.created_at) 
                ORDER BY time ASC",
            parseTimeZone(@input.timezone),
            @input.userid,
            @input.groupid,
            )

            i = 0
            while (i < 24)
                check = true
                daily_posts.each do |count|
                    if count[0].to_i == i
                count[0] = count[0].to_i
                        check = false
                    end
                end

                if check == true
                    daily_posts.push([i,0])
                end
                i += 1
            end

            daily_posts.sort! {|a,b| a[0] <=> b[0]}

            daily_posts.each do |count|
                count[0] = Time.parse("#{count[0].to_i}:00").strftime("%l %P")
            end

            weekly_posts = $database.execute( "SELECT strftime('%w', messages.created_at) AS time, count(strftime('%w', messages.created_at)) 
                FROM messages 
                    WHERE messages.user_id = ? 
                    AND messages.group_id = ?
                    AND messages.user_id != 'system' 
                GROUP BY strftime('%w', messages.created_at) 
                ORDER BY time ASC",
            @input.userid,
            @input.groupid,
            )
            headers['Content-Type'] = "application/json"

            i = 0
            while (i < 7)
                check = true
                weekly_posts.each do |count|
                    if count[0].to_i == i
                        count[0] = count[0].to_i
                        check = false
                    end
                end

                if check == true
                    weekly_posts.push([i,0])
                end
                i += 1
            end

            weekly_posts.sort! {|a,b| a[0] <=> b[0]}
            weekly_posts.each do |count|
                date = Date.new(2014,6,15 + count[0])
                count[0] = date.strftime("%A")
            end

    	    result.merge!(
                :name => userInfo['name'], 
                :avatar => userInfo['avatar_url'], 
                :top_post => top_post,
                :top_images => top_images, 
                :total_posts => total_posts, 
                :total_likes_received => total_likes_received, 
                :post_percentage => ((total_posts.to_f/total_posts_for_group.to_f) * 100).round(2), 
                :group_name => group_name, 
                :num_of_images => num_of_images,
                :heatmap => heatmap, 
                :daily_posts => daily_posts, 
                :weekly_posts => weekly_posts)
	
        else
            $logger.info "Grabbing global user-data for userid #{@input.userid} for @state.token = #{@state.token}"
                result = @state.scraper.getUserInfo
                result = result['response']
            
             #"At a Glance" Total Posts  
             total_posts = $database.execute("SELECT count(messages.user_id) AS count 
                 FROM messages 
                     WHERE messages.user_id=?",
             @input.userid
             )[0][0]
              
             #"At a Glance" Total Likes
             total_likes_received = $database.execute("SELECT count(likes.user_id) AS count 
                 FROM likes 
                 LEFT JOIN messages ON messages.message_id=likes.message_id 
                     WHERE messages.user_id=?",
             @input.userid
             )[0][0]

             if (total_likes_received.to_f == 0 || total_posts.to_f == 0)
                 result.merge!(:likes_to_posts_ratio => 0)
             else
                 result.merge!(:likes_to_posts_ratio => total_likes_received.to_f/total_posts.to_f)
             end
            
             #"At a Glance" Top Posts
             top_post = $database.execute("SELECT count(likes.user_id) AS count, messages.text 
                 FROM likes 
                 JOIN messages ON messages.message_id=likes.message_id 
                     WHERE messages.user_id=? 
                     AND messages.image=='none' 
                 GROUP BY messages.message_id 
                 ORDER BY count DESC LIMIT 5",
             @input.userid,
             )
                
             #"At a Glance" Number of groups
             num_of_groups = $database.execute("SELECT count(user_groups.group_id) 
                 FROM user_groups 
                     WHERE user_groups.user_id = ?",
             @input.userid
             )[0][0]

             #"At a Glance" Number of images posted
             num_of_images = $database.execute("SELECT count(messages.image) 
                 FROM messages 
                     WHERE messages.user_id = ?
                     AND messages.image != 'none'",
             @input.userid
             )[0][0]

             #"At a Glance" Number of Avatar changes
             num_of_avatars = $database.execute("SELECT messages.avatar_url 
                 FROM messages 
                     WHERE messages.user_id = ? 
                 GROUP BY messages.avatar_url",
             @input.userid
             ).length - 1

             #"At a Glance" Top images
             top_images = $database.execute("SELECT count(likes.user_id) AS count, messages.text, messages.image
                 FROM likes
                 JOIN messages ON messages.message_id=likes.message_id
                     WHERE messages.user_id = ?
                     AND messages.image!='none'
                 GROUP BY messages.message_id
                 ORDER BY count DESC LIMIT 6", 
             @input.userid,
             )
            
             #"At a Glance" Posts by group
             $database.results_as_hash = false
             group_posts = $database.execute("SELECT groups.name, count(messages.message_id) as count from messages 
                 LEFT JOIN groups ON messages.group_id = groups.group_id 
                     WHERE messages.user_id = ? 
                 GROUP BY messages.group_id
                 ORDER BY count DESC",
             @input.userid
             )
            
             #"At a Glance" Heatmap
             heatmap = $database.execute( "SELECT strftime('%w',messages.created_at) AS date,strftime('%H',messages.created_at, ?) AS hour, count(message_id) 
                 FROM messages
                 JOIN groups USING(group_id)
                     WHERE user_id = ?
                     AND messages.user_id != 'system'
                 GROUP BY strftime('%w',messages.created_at), strftime('%H',messages.created_at)
                 ORDER BY strftime('%w',messages.created_at) asc, strftime('%H',messages.created_at)",
             parseTimeZone(@input.timezone),
             @input.userid
             )
             #todo: enforce user id
             heatmap.each do |a|
                 a[1] = a[1].to_i
                 a[0] = a[0].to_i
             end

             # Need to loop through the returned values, and add 0s for any missing day/hour combos
             i, j = 0, 0
             while (i < 7)
                 while (j < 24)
                     check = true
                     heatmap.each do | count |
                         if (count[0] == i && count[1] == j)
                             check = false
                         end
                     end
                     if check
                         heatmap.push([i,j,0])
                     end
                     j += 1
                 end
                 i += 1
                 j = 0
             end
 
             #"At a Glance" Posts by hour
             daily_posts = $database.execute( "SELECT strftime('%H', messages.created_at, ? ) AS time, count(strftime('%H', messages.created_at, '-04:00')) 
                 FROM messages 
                     WHERE messages.user_id=? 
                     AND messages.user_id != 'system' 
                 GROUP BY strftime('%H', messages.created_at) 
                 ORDER BY time ASC",
             parseTimeZone(@input.timezone),
             @input.userid
             )
 
             i = 0
             while (i < 24)
                 check = true
                 daily_posts.each do |count|
                     if count[0].to_i == i
                 count[0] = count[0].to_i
                         check = false
                     end
                 end
 
                 if check == true
                     daily_posts.push([i,0])
                 end
                 i += 1
             end
 
             daily_posts.sort! {|a,b| a[0] <=> b[0]}
 
             daily_posts.each do |count|
                 count[0] = Time.parse("#{count[0].to_i}:00").strftime("%l %P")
             end
 
             #"At a Glance" Posts by day
             weekly_posts = $database.execute( "SELECT strftime('%w', messages.created_at) AS time, count(strftime('%w', messages.created_at)) 
                 FROM messages 
                     WHERE messages.user_id=? 
                     AND messages.user_id != 'system' 
                 GROUP BY strftime('%w', messages.created_at) 
                 ORDER BY time ASC",
             @input.userid
             )
             headers['Content-Type'] = "application/json"
 
             i = 0
             while (i < 7)
                 check = true
                 weekly_posts.each do |count|
                     if count[0].to_i == i
                         count[0] = count[0].to_i
                         check = false
                     end
                 end
 
                 if check == true
                     weekly_posts.push([i,0])
                 end
                 i += 1
             end
 
             weekly_posts.sort! {|a,b| a[0] <=> b[0]}
             weekly_posts.each do |count|
                 date = Date.new(2014,6,15 + count[0])
                 count[0] = date.strftime("%A")
             end
 
             #Add all "At a Glance" stats to a hash and return it
             result.merge!(
                :total_posts => total_posts,
                :total_likes_received => total_likes_received,
                :top_post => top_post,
                :num_of_groups => num_of_groups, 
                :num_of_images => num_of_images, 
                :num_of_avatars => num_of_avatars, 
                :top_images => top_images, 
                :group_posts => group_posts, 
                :heatmap => heatmap, 
                :daily_posts => daily_posts, 
                :weekly_posts => weekly_posts)
        end
        
    	$database.results_as_hash = false        
        return result.to_json
    end
  end
  
  class Group < R '/rest/group'
    def get()
        if !getGroups(@input.groupid)
            return 'nil'
        end
 
        $database.results_as_hash = true
        result = $database.execute( "SELECT groups.group_id, groups.name, groups.image, groups.updated_at 
            FROM groups join user_groups on groups.group_id = user_groups.group_id 
            where user_groups.user_id = ? and groups.group_id = ?", 
            @state.user_id,
            @input.groupid
        )
        if(result.length == 0)
            @status = 400
            return "";
        end
        
        users = $database.execute( "select user_id, user_groups.name from users
            join user_groups using(user_id)
            join groups using (group_id)
            where groups.group_id = ?", 
            @input.groupid
            )
        result[0].merge!(:users => users);
        $database.results_as_hash = false
        return result[0].to_json
    end
  end
  
  class ScrapeGroup < R '/rest/scrapegroup'
    def get()
        if !getGroups(@input.groupid)
            return 'nil'
        end

        @state.scraper.scrapeNewMessages(@input.groupid)
    end
  end

  class TopPost < R '/rest/toppost'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end
        if(@input.num == nil)
            @input.num = 1
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        $database.results_as_hash = true
        topPosts = $database.execute( "select count(likes.user_id) as count, messages.text, user_groups.Name, users.avatar_url 
        from likes 
        join messages on messages.message_id=likes.message_id 
        left join user_groups on user_groups.user_id=messages.user_id 
        left join users on users.user_id=messages.user_id 
            WHERE messages.created_at > datetime('now', ?) 
            AND messages.group_id=? 
            AND user_groups.group_id=? and messages.image=='none' 
        group by messages.message_id 
        order by count desc limit ?",
        "-" + @input.days + " day",
        @input.groupid,
        @input.groupid,
        @input.numpost)
        
        topImages = $database.execute("select count(likes.user_id) as count, messages.text, messages.image, user_groups.Name, users.avatar_url 
	from messages
	left join likes using(message_id)
	left join user_groups on user_groups.user_id=messages.user_id 
	left join users on users.user_id=messages.user_id 
	    WHERE messages.created_at > datetime('now', ?) 
	    AND messages.group_id=? AND user_groups.group_id=? 
	    AND messages.image!='none' 
	group by messages.message_id 
	order by count desc limit ?",
        "-" + @input.days + " day",
        @input.groupid,
        @input.groupid,
	@input.numimage) 
        headers['Content-Type'] = "application/json"
        $database.results_as_hash = false
        return { :posts => topPosts, :images => topImages }.to_json
    end
  end

  class WordCloud < R '/rest/wordcloud'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        result = $database.execute( "SELECT text FROM messages WHERE messages.created_at > datetime('now', ?) AND group_id=?",
        "-" + @input.days + " day",
        @input.groupid)

        stop_words = Array.new
        f = File.open(File.join(File.expand_path(File.dirname(__FILE__)), 'commonlyusedwords.txt') )
        f.each_line do | line |
            stop_words.push line.split("\n")
        end

        counts = Hash.new 0
        #counts = Array.new 0
        result.each do | text |
            stop_words.each do | stop_word |
                if text[0].to_s.downcase.include? stop_word[0].downcase
                    text[0].gsub!(/(^|\s|\W)#{stop_word[0].to_s}(\'s|\s|\W|$)/i, ' ')
                end
            end
            text[0].split.each do | word |
                word = word.downcase
                word.delete!("^a-zA-Z0-9")
                counts[word] += 1
                #if counts.find {|w| w[:text] == word}
                    #counts.find {|w| w[:text] == word}[:size] += 1
                #else
                    #counts.push({:text => word, :size => 1})
                #end
            end

        end

        final = Array.new 0
        counts.each do | x |
            final.push(x.to_a)
        end
        headers['Content-Type'] = "application/json"
        return result.to_json
        #return counts.to_a
    end 
  end

  class TotalLikesGiven < R '/rest/totallikesgiven'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        result = $database.execute( "select user_groups.Name, count(likes.user_id) as count from likes left join user_groups on user_groups.user_id=likes.user_id left join messages on messages.message_id=likes.message_id where messages.created_at > datetime('now', ?) and messages.group_id=? and user_groups.group_id=? group by likes.user_id order by count desc",        
        "-" + @input.days + " day",
        @input.groupid,
        @input.groupid)
        headers['Content-Type'] = "application/json"
        return result.to_json
    end
  end
      
  class PostsMost < R '/rest/postsmost'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end
        
        topPosters = $database.execute( "SELECT user_groups.Name, count(messages.user_id) as count
            FROM user_groups
            left join messages using(user_id)
            WHERE messages.created_at > datetime('now', ?)
            AND messages.group_id=?
            AND user_groups.group_id=?
            group by messages.user_id order by count desc",
        "-" + @input.days + " day",
        @input.groupid,
        @input.groupid)
        
        likesGotten = $database.execute( "select user_groups.Name, count(likes.user_id) as count
        from user_groups 
        left join messages using(user_id)
        left join likes using(message_id)
        where messages.created_at > datetime('now', ?) 
        and messages.group_id=? 
        and user_groups.group_id=? 
        group by messages.user_id
        order by (select count(messages.user_id) from messages where user_id = user_groups.user_id and group_id = ? and messages.created_at > datetime('now', ?)) desc",
        "-" + @input.days + " day",
        @input.groupid,
        @input.groupid,
        @input.groupid,
        "-" + @input.days + " day")
        
        headers['Content-Type'] = "application/json"
        return { "posters" => topPosters, "likesGotten" => likesGotten }.to_json
    end
  end

  class DailyPostFrequency < R '/rest/dailypostfrequency'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        result = $database.execute( "select strftime('%H', messages.created_at, ? ) as time, count(strftime('%H', messages.created_at, '-04:00')) from messages where messages.group_id=? and messages.user_id != 'system' group by strftime('%H', messages.created_at) order by time asc",
        parseTimeZone(@input.timezone),
        @input.groupid)
        headers['Content-Type'] = "application/json"
       
	#Need to loop through the returned values, and add 0s for any missing hours
        i = 0
        while (i < 24)
            check = true
            result.each do |count|
                if count[0].to_i == i
		    count[0] = count[0].to_i
                    check = false
                end
            end

            if check == true
                result.push([i,0])
            end
            i += 1
        end

        result.sort! {|a,b| a[0] <=> b[0]}

        result.each do |count|
            count[0] = Time.parse("#{count[0].to_i}:00").strftime("%l %P")
        end

        return result.to_json
    end
  end

  class WeeklyPostFrequency < R '/rest/weeklypostfrequency'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        result = $database.execute( "select strftime('%w', messages.created_at) as time, count(strftime('%w', messages.created_at)) from messages where messages.group_id=? and messages.user_id != 'system' group by strftime('%w', messages.created_at) order by time asc",
        @input.groupid)
        headers['Content-Type'] = "application/json"

        i = 0
        while (i < 7)
            check = true
            result.each do |count|
                if count[0].to_i == i
                    count[0] = count[0].to_i
                    check = false
                end
            end

            if check == true
                result.push([i,0])
            end
            i += 1
        end

        result.sort! {|a,b| a[0] <=> b[0]}
        result.each do |count|
            date = Date.new(2014,6,15 + count[0])
            count[0] = date.strftime("%A")
        end
        return result.to_json
    end
  end
  
  class Heatdata < R '/rest/heatdata'
    def get()
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end
        
        $database.results_as_hash = false
        result = $database.execute( "select strftime('%w',messages.created_at) as date,strftime('%H',messages.created_at, ?) as hour, count(message_id) from messages
                join groups using(group_id)
                where group_id = ?
		and messages.user_id != 'system'
                group by strftime('%w',messages.created_at), strftime('%H',messages.created_at)
                order by strftime('%w',messages.created_at) asc, strftime('%H',messages.created_at)",
            parseTimeZone(@input.timezone), 
            @input.groupid)
        #todo: enforce user id
        result.each do |a|
            a[1] = a[1].to_i
            a[0] = a[0].to_i
        end

	# Need to loop through the returned values, and add 0s for any missing day/hour combos
	i, j = 0, 0
	while (i < 7)
	    while (j < 24)
		check = true 
		result.each do | count |
		    if (count[0] == i && count[1] == j)
		        check = false
		    end
		end
		if check 
		    result.push([i,j,0])
		end
		j += 1
	    end
	    i += 1
	    j = 0
	end

        $database.results_as_hash = false
        return result.to_json
    end
  end
  
  class VolumData < R '/rest/volumedata'
    def get()
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end
        
        groupBy = '%m';
        if(@input.byWeek == "true")
            groupBy = '%W';
        end
        
        byUser = (@input.byUser == "true")
        
        $database.results_as_hash = false
        if(byUser)
            result = $database.execute( "select time, cast(numMessage as real)/count(user_id) as count
                from (select strftime('%s',created_at) as time, count(message_id) as numMessage, group_id
                            from messages where group_id = ?
                            group by strftime(?, created_at), strftime('%Y', created_at)
                            order by strftime('%s', created_at)
                )
                left join user_groups using(group_id)
                left join (select user_id, min(created_at) as firstpost from messages join users using(user_id) where messages.group_id = ? 
		and messages.user_id != 'system'
		group by user_id)
		using (user_id)
                where strftime('%s',firstpost) <= time
                group by time",
                @input.groupid,
                groupBy,
                @input.groupid)
        else
            result = $database.execute( "select strftime('%s',created_at) as time, count(message_id)
                from messages where group_id = ?
		and messages.user_id != 'system'
                group by strftime(?, created_at), strftime('%Y', created_at)
                order by strftime('%s', created_at)",
                @input.groupid,
                groupBy)
        end
        
        
        #todo: enforce user id
        result.each do |a|
            curr = DateTime.strptime(a[0].to_s,'%s')
            if(@input.byWeek == "true")
                a[0] = (curr.to_date - curr.wday).to_time.to_i * 1000 #convert to sunday
            else
                a[0] = (curr.to_date - (curr.day-1)).to_time.to_i * 1000 #convert to beginning of month
            end
            
            if(byUser)
                a[1] = a[1].round(1)
            end
        end
        $database.results_as_hash = false
        return result.to_json
    end
  end

  class GroupJoinRate < R '/rest/groupjoinrate'
    def get()
        if(@input.days == nil)
            @input.days = "9999999999"
        end
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end
        if(@input.num == nil)
            @input.num = 1
        end

        if !getGroups(@input.groupid)
            return 'nil'
        end

        #$database.results_as_hash = true
        temp_result = $database.execute( "SELECT strftime('%s', MIN(m.created_at)) First_Post, ug.name
            FROM messages m       
                 INNER JOIN user_groups ug
                       ON m.group_id = ug.group_id
                          AND m.user_id = ug.user_id           
                   INNER JOIN groups g        
                         ON ug.[group_id] = g.[group_id]   
            WHERE m.group_id=?
            GROUP BY g.[name], ug.name
            ORDER BY First_Post",
        @input.groupid)

        i = 0
        result = Array.new 
        categories = Array.new
        temp_result.each do | element |
            result.push([1000*element[0].to_i, i])
            categories.push(element[1])
            i += 1
        end
        toReturn = [:data => result, :categories => categories]
        headers['Content-Type'] = "application/json"
        $database.results_as_hash = false
        return toReturn.to_json
    end
  end
  
  class NgramData < R '/rest/ngramdata'
    def get()
        if(@input.groupid == nil)
            @status = 400
            return 'need group id'
        end
        if(@input.search == nil)
            @status = 400
            return 'need search terms'
        end
        terms = @input.search.split(",")
        toReturn = { :series => []};
        $database.results_as_hash = false
        
        dateRange = $database.execute("select strftime('%s', created_at), strftime('%s', updated_at) from groups where group_id = ?",
            @input.groupid);
        toReturn["startDate"] = dateRange[0][0].to_i * 1000
        toReturn["endDate"] = dateRange[0][1].to_i * 1000
        terms.each do |term|
            chartdata = [];
            $database.results_as_hash = true
            #alternate query that doesn't return 0 weeks, but is much faster
            #result = $database.execute( "select strftime('%s', m.created_at) as time, count(message_id) as messages,
            #   (select count(message_id) from messages
            #        where group_id = ?
            #        and strftime('%W', messages.created_at) = strftime('%W', m.created_at)
            #        and strftime('%Y', messages.created_at) = strftime('%Y', m.created_at)
            #        group by strftime('%W', messages.created_at), strftime('%Y', messages.created_at)
            #        order by messages.created_at asc
            #   ) as totalmessages
            # from messages as m
            #    where group_id = ?
            #    and text like ?
            #    group by strftime('%W', m.created_at), strftime('%Y', m.created_at)
            #    order by m.created_at asc",
            #    @input.groupid,
            #    @input.groupid,
            #    '%'+term+'%')
                
            result = $database.execute( "select strftime('%s', m.created_at) as time, count(message_id) as totalmessages,
                   (select count(message_id) from messages
                        where group_id = ?
                        and strftime('%m', messages.created_at) = strftime('%m', m.created_at)
                        and strftime('%Y', messages.created_at) = strftime('%Y', m.created_at)
                        and text like ?
                   ) as messages
                 from messages as m
                where group_id = ?
                and m.user_id != 'system'
                group by strftime('%m', m.created_at), strftime('%Y', m.created_at)
                order by m.created_at asc",
                @input.groupid,
                '%'+term+'%',
                @input.groupid)   
                
            result.each do |a|
                if(a["messages"] == nil)
                    chartdata.push([a["time"].to_i * 1000, 0])
                else
                    chartdata.push([
                            a["time"].to_i * 1000, #highcharts likes dates in milliseconds
                            ((a["messages"].to_f / a["totalmessages"])*100).round(3)
                        ]);
                end
            end
            currseries = {:data => chartdata, :name => term};
            toReturn[:series].push(currseries);
        end
        #todo: enforce user id
        
        $database.results_as_hash = false
        
        return toReturn.to_json
    end
  end
end

module GroupStats::Views
    def initalAuth
        p "Welcome to my blog"
    end
end
