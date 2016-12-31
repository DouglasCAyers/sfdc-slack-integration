public with sharing class SlackWebApi {

    public class SlackMessage {

        @InvocableVariable( label = 'Channel' required = true )
        public String channel;

        @InvocableVariable( label = 'Message' required = true )
        public String text;

        @InvocableVariable( label = 'As User' required = false description = 'Should this post as the currently logged in user?' )
        public Boolean as_user = true;

        @InvocableVariable( label = 'Username' required = false description = 'Name of user or bot that this message should post as. Post As User must be false.' )
        public String username;

        @InvocableVariable( label = 'Markdown?' required = false description = 'Should message be formatted in Slack (true) or plain text (false)?' )
        public Boolean mrkdwn = true;

    }

    @InvocableMethod( label = 'Post Message to Slack' )
    public static void postMessage( List<SlackMessage> messageList ) {

        if ( messageList != null ) {

            for ( SlackMessage message : messageList ) {

                System.debug( 'processing message: ' + message );

                // convert message to slack compliant markdown
                message.text = convertToSlackMarkdown( message.text );

                QueueableSlackCall call = new QueueableSlackCall(
                    'callout:Slack/chat.postMessage',
                    'POST',
                    createPostBody( message )
                );

                System.enqueueJob( call );

            }

        }

    }

    private static String convertToSlackMarkdown( String html ) {

        // content must be wrapped in a single root tag
        // else DOM Document parsing fails with "start tag not allowed in epilog"
        //
        // WRONG:
        //      "<p>sibling 1</p> <p>sibling2</p>"
        //
        // CORRECT:
        //      "<p> <p>sibling 1</p> <p>sibling 2</p> </p>"

        html = '<p>' + html + '</p>';

        // when chatter posts are created from emails then links are enclosed between < >
        // but the DOM Document parser will think those are tags to be interpreted and when
        // it gets to the // part of https:// it thinks the first / is the self-closing terminator
        // and complains that it next sees another / but expected > to terminate the tag.
        // so, just encode those characters instead
        Matcher myMatcher = Pattern.compile( '<([a-zA-Z]+:\\/\\/(.+))>' ).matcher( html );
        while ( myMatcher.find() ) {
            myMatcher.replaceAll( '&lt;$1&gt;' );
        }

        DOM.Document doc = new DOM.Document();

        try {
            doc.load( html );
            return walkThrough( doc.getRootElement() );
        }
        catch ( System.XmlException xe ) {
            System.debug( LoggingLevel.ERROR, xe );
            return xe.getMessage();
        }

    }

    private static String prefix = '';
    private static Integer indentLevel = 0;

    private static String walkThrough( DOM.XMLNode node ) {

        System.debug( 'Walking through node: ' + node );

        String result = '';

        if ( node.getNodeType() == DOM.XMLNodeType.TEXT ) {

            System.debug( 'text node: ' + node.getText() );

            result += parseText( node.getText() );

            System.debug( 'returning: ' + result );

            return result;

        }

        if ( node.getNodeType() == DOM.XMLNodeType.ELEMENT ) {

            System.debug( 'element node: ' + node.getName() );

            // if tags should be converted to mark down then
            // do that within this block

            if ( node.getName() == 'ul' ) {
                prefix = '•';
                indentLevel++;
            }
            else if ( node.getName() == 'ol' ) {

                if ( String.isBlank( prefix ) ) {
                    prefix = '1';
                }
                else if ( prefix.isNumeric() ) {
                    prefix = String.valueOf( Integer.valueOf( prefix ) + 1 );
                }

                indentLevel++;
            }
            else if ( node.getName() == 'b' ) {
                result += '*';
            }
            else if ( node.getName() == 'i' ) {
                result += '_';
            }
            else if ( node.getName() == 's' ) {
                result += '~';
            }
            else if ( node.getName() == 'li' ) {

                result += '\n';

                if ( String.isNotBlank( prefix ) ) {

                    result += ' '.repeat( indentLevel * 2 ) + prefix + ' ';

                    if ( prefix.isNumeric() ) {
                        prefix = String.valueOf( Integer.valueOf( prefix ) + 1 );
                    }

                }

            }

            System.debug( 'result now is: ' + result );

            for ( Dom.XMLNode child: node.getChildElements() ) {
                System.debug( 'child element: ' + child );
                result += walkThrough( child );
            }

            System.debug( 'result now is: ' + result );

            if ( String.isNotBlank( node.getText() ) ) {
                System.debug( 'appending node text: ' + node.getText() );
                result += parseText( node.getText() );
            }

            System.debug( 'result now is: ' + result );

            if ( node.getName() == 'p' ) {
                result += '\n';
            }
            else if ( node.getName() == 'ul' || node.getName() == 'ol' ) {
                result += '\n';
                prefix = '';
                indentLevel--;
            }
            else if ( node.getName() == 'b' ) {
                result += '*';
            }
            else if ( node.getName() == 'i' ) {
                result += '_';
            }
            else if ( node.getName() == 's' ) {
                result += '~';
            }

            result += ' ';

            System.debug( 'returning result: ' + result );

            return result;

        }

        return '';  //should never reach here

    }

    private static String parseText( String text ) {

        String result = text;

        // escape unicode changes the HTML &nbsp; which looks like whitespace, but isn't, to \u00A0
        // if we don't do this then methods like String.isBlank() and String.trim() don't do what you expect.
        // note, in the replaceAll() call we have to escape \u for apex so it becomes \\u then escape for regex so it becomes \\\\u
        result = result.escapeUnicode();
        result = result.replaceAll( '\\\\u00A0', ' ' );

        // escape characters for slack formatting
        // https://api.slack.com/docs/message-formatting
        result = result.replaceAll( '&', '&amp;' );
        result = result.replaceAll( '<', '&lt;' );
        result = result.replaceAll( '>', '&gt;' );

        // be gone ye extra whitespace!
        result = result.normalizeSpace();

        return result;
    }

    private static String createPostBody( Object obj ) {

        // go ahead and add token to body. this uses merge parameters so the named credentials
        // must support merge parameters on the http body
        String body = 'token={!$Credential.OAuthToken}';

        // Convert object to map so we can iterate properties and append to body
        Map<String, Object> objMap = (Map<String, Object>) JSON.deserializeUntyped( JSON.serialize( obj ) );

        if ( objMap != null ) {

            for ( String key : objMap.keySet() ) {

                Object val = objMap.get( key );

                if ( val instanceof String ) {
                    val = EncodingUtil.urlEncode( (String) val, 'UTF-8' );
                }

                body += '&' + key + '=' + val;

            }

        }

        System.debug( body );

        return body;

    }

    /**
     * Class taken from http://coenraets.org/blog/2016/01/slack-salesforce-integration/
     */
    public class QueueableSlackCall implements System.Queueable, Database.AllowsCallouts {

        private final String url;
        private final String method;
        private final String body;

        public QueueableSlackCall( String url, String method, String body ) {
            this.url = url;
            this.method = method;
            this.body = body;
        }

        public void execute( System.QueueableContext ctx ) {

            HttpRequest req = new HttpRequest();

            req.setEndpoint( url );
            req.setMethod( method );
            req.setBody( body );

            Http http = new Http();

            System.debug( '--Request--' );
            System.debug( req );
            System.debug( req.getBody() );
            System.debug( '----' );

            HttpResponse res = http.send( req );

            System.debug( '--Response--' );
            System.debug( res );
            System.debug( res.getBody() );
            System.debug( '----' );

        }

    }

}
