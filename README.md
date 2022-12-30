Assuming you are part of a company or at the university where lots of people are within the same LAN network but using different computer systems. Typically when you want to share a file between two PC's you have to do more or less always this steps.

- Create a place where both users have read / write access
- Copy the files to the place
- Copy the files from the place to your local device

This process is not even always possible and really anoying.

The Ntools provide a simple solution.

After a [optional] onetime setup you can easy share files / folders within two PC's by doing the following.

-Sender: open "npush" application give the files you want to send as params
-Receiver: open "npoll" on the location where you want the files to be stored.

And thats it. No  other setup is needed, the files are copied instantaniosly, when copying large files press "i" and you get printed out a short progress information. After Successfully file transfer both, sender and receiver app close automatically.

!! Attention !!
Giving that much comfort comes with the cost of security. When "npush" is searching for a "npoll" instance to send the files to there is no validation progress. The first instance that answers the requests gets the data. Therefore the connection can be hijacked during the startup, if a connection is established then it is as secure as unencrypted TCP/IP connections can be.

If you do not want the code but the binary you can the following link:

https://www.corpsman.de/klickcounter.php?url=download/ntools.zip


The Code is dependant to the Lazarus "L-Net" library
