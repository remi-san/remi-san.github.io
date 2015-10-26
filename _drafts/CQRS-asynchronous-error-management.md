---
layout: post
title: "CQRS Asynchronous Error Management"
date: 2015-10-30 12:00:00
categories: CQRS
excerpt: How do you warn your user when a command failed when your command handler is async?
keywords: CQRS, Async, Exceptions, Events, Domain
---
So, I've got a design problem.

I've got an aggregate that throws domain exceptions when **valid** commands would break invariants (yep, guys, that's a real thing). I know, exceptions shouldn't be used to do that, but, let's face it, it is a lot simpler like this: exceptions are great when you're talking about preventing to alter your domain and reject the command: that's what they've been created for (OK, maybe not really what it's been created for, but they're great at it).

It looks like this.
{% highlight PHP linenos %}
<?php
class FooAggregateRoot
{
    ...
    
    public function foo($bar)
    {
        if (...) { // Invalid condition
            throw new DomainException(...); // The domain exception
        }
    }
}
{% endhighlight %}

Problem is, if my handler is asynchronous, the command would just be rejected (as I planned it to be), but I have no way to warn the user who issued the failing command, as the exception cannot be propagated back to the command issuer. And **I WANT** him to be notified if it fails.

Of course, the easy way would be to say "If you really need your user to be notified right away, just make your handler synchronous and you won't have a problem anymore"... well, that's true, but let's pretend that, for various reasons, **I NEED** it to be asynchronous. So, I've got to find a way to throw that exception back (or do something that looks like it).

As you have to communicate with the external world through events, the evident solution would be to transform those domain exceptions into domain error events. So, let's try it.

## The Exception Way

*Summary of the situation before modification: we've got our command handler which will get the aggregate through its repository, make the domain action described by the command, and finally, the repository saving the modified aggregate and emitting the events outside (through its* embedded *event bus):*
{% highlight PHP linenos %}
<?php
public function handleFooCommand(FooCommand $command)
{
    $domainAggregate = $this->domainAggregateRepository->load($command->getAggregateId());
    $domainAggregate->foo($command->getBar()); // throws the domain exception
    $this->domainAggregateRepository->save($domainAggregate); // saves the aggregate and emits the events
}
{% endhighlight %}

Given that, if we want to notify the outside world the command failed, as the save method of the repository wasn't reached, we'll have to put our exception management structure around it and emit the "error" event here. This should look like this:
{% highlight PHP linenos %}
<?php
public function handleFooCommand(FooCommand $command)
{
    try {
        ... //still does the same stuff as previously
    } catch (DomainException $e) {
        $this->eventBus->emit(new DomainErrorEvent(...));
    } catch (Exception $e) {
        ... // log and fix bug
    }
}
{% endhighlight %}

Sadly, doing so, you will be doing business stuff outside of your aggregate and emitting events from two different layers, and that's something you don't really want to do either. Then, so long for this solution, let's forget about it and move on.

## The DomainErrorEvent Way

So I've looked it up on *Google* and found some interesting stuff about it. First, there's this [question asked](https://groups.google.com/forum/#!topic/dddcqrs/Qd5afPyX6e8), and especially some of the answers which lead me to this [article](http://thinkbeforecoding.com/post/2009/12/10/Business-Errors-are-Just-Ordinary-Events), and bottom-line is *"Why bother and don't treat error cases like just any other event?"*.

And yeah, why the fuck not? It sure is pretty tempting and, anyway, the exception way failed (after all, there's a reason why a lot of CQRS experts say you shouldn't use them that way).

But, wait a second... Why the hell would I want to emit an event that won't modify my aggregate (and store it if it's event sourced)? That doesn't make any sense (does it?). And what if, before breaking invariants, my command has already emitted another event which would have modified my aggregate. I certainly don't want that (I mean, you could want that, but if you don't, it really sucks).

So, what should I do? Save those domain *error* events like any other **OR** find another way to do it? I've already fucked up with exceptions, and I survived the shame, so let's try to do it the other way then, and see where it leads us. If it fails, we'll see.

To do that, we want the event created inside the aggregate root but don't want to save the aggregate to prevent other events from being dispatched. That way, we shouldn't have any of the undesirable side effects.

'should look like this.
{% highlight PHP linenos %}
<?php
class FooAggregateRoot extends EventSourcedAggregateRoot // Yep, I'm using broadway (and you should too ;P)
{
    ...
    
    /**
     * @var Event
     */
    private $errorEvent; // Where the event is stored before being sent by our event bus
    
    public function foo($bar)
    {
        if (...) { // Invalid condition
            $this->emitErrorEvent(new DomainErrorEvent(...)); // create the domain error event
            return;
        }
        ... // do the right stuff here
    }
    
    ...
    
    /**
     * The method to call to let the system know it'll have to dispatch an error event
     */
    public function emitErrorEvent(DomainErrorEvent $event)
    {
        $this->errorEvent = $event;
    }
    
    public function getErrorEvent()
    {
        return $this->errorEvent;
    }
}
{% endhighlight %}
{% highlight PHP linenos %}
<?php
public function handleFooCommand(FooCommand $command)
{
    try {
        $domainAggregate = $this->domainAggregateRepository->load($command->getAggregateId());
        $domainAggregate->foo($command->getBar()); // throws the domain exception
        
        if ($domainAggregate->getErrorEvent() !== null) {
            $this->eventBus->emit($domainAggregate->getErrorEvent()); // emit error event if there's one
        } else {
            $this->domainAggregateRepository->save($domainAggregate); // else saves the aggregate and emits the events
        }
    } catch (Exception $e) {
        ... // log and fix bug
    }
}
{% endhighlight %}

But wait! Are we emitting from two different layers again? Ok, so this was just one more crappy idea after all... You can tell me I could have done it inside the Repository, and yes, I could have done that. But does it really make sense to call a method `save` if you can prevent it to really save the passed object? Yeah, that's what I thought.

So, what's the big deal about emitting (and saving) error events just like any other event? Do we even need to separate error events from *regular* events? Does it make sense? After those two failures trying to avoid the inevitable, I'm not that certain anymore.

Do I really want to discard those "failed" commands results? Those were valid commands after all.

## The Right Way

Maybe now is the time to go back to your domain experts and try to find a domain way to deal with it, it's not a bug after all, and if it is, fix it. And who knows, maybe they'll want to make some stats about how often `foo` calls failed and you'll have found a reason to store them.

Nonetheless, we still got one major problem: what do we do about events resulting in a modification of our aggregate that were sent before our *error* event?

Well, are you sure those events should have been emitted? If not, take them out of your code and swear not to do it ever again. Otherwise (in very rare cases, it can happen), maybe you should change the order of the calls and think it all over again, or maybe, it doesn't matter. Once again, ask your domain experts how to do it, only them can know.

It's DDD for fuck's sake, it's by forgetting that (and trying to bring a technical answer instead of a domain one) we ended up in deep shit the two first times.

So, finally, we end up with that:
{% highlight PHP linenos %}
<?php
class FooAggregateRoot extends EventSourcedAggregateRoot
{
    ...
    
    public function foo($bar)
    {
        if (...) { // Invalid condition
            $this->apply(new IThoughtThisWasAnErrorButNoItSADomainEvent(...)); // create the domain event
            return; // or don't, your domain experts will tell you what to do
        }
        ... // do the right stuff here
    }
    
    ...
    
    /**
     * The method applying the event
     */
    public function applyIThoughtThisWasAnErrorButNoItSADomainEvent(IThoughtThisWasAnErrorButNoItSADomainEvent $event)
    {
        // Do nothing (or something maybe)
    }
}
{% endhighlight %}
{% highlight PHP linenos %}
<?php
public function handleFooCommand(FooCommand $command)
{
    try {
        $domainAggregate = $this->domainAggregateRepository->load($command->getAggregateId());
        $domainAggregate->foo($command->getBar()); // throws the domain exception
        $this->domainAggregateRepository->save($domainAggregate); // will save the aggregate and dispatch the events (no more funny stuff here)
    } catch (Exception $e) {
        ... // log and fix bug
    }
}
{% endhighlight %}

And that's it! Everything should work just fine now. You've got your *error (which isn't one)* case handled and you can warn your user. Hooray! Design problem solved.

And remember boys and girls, if it walks like a duck, swims like a duck and quacks like a duck, not only you're right to call it a duck, but stop trying to call it something else and stop being stubborn like me.

See you for another adventure very soon.